"""W3 on Kubeflow: training pipeline with a continuous-training loop.

  detect new data -> validate -> train -> evaluate -> gate -> register -> deploy

Compiled with the KFP SDK and run as a recurring run. KFP has no data-event
trigger, so "retrain on new data" is a cron schedule plus a first step that
compares the dataset fingerprint with the one the last model was trained on.

The shared test kit is mounted from a ConfigMap at /testkit (the lab has no
image registry; a real setup would bake it into an image in CI).
"""
from kfp import compiler, dsl, kubernetes

BASE_IMAGE = "python:3.11-slim"
# KFP only accepts literal env values, so the endpoint cannot be a pipeline parameter.
S3_ENDPOINT = "http://minio-service.kubeflow.svc.cluster.local:9000"
PACKAGES = ["pandas==2.2.3", "scikit-learn==1.6.1", "boto3==1.35.99", "joblib==1.4.2"]


@dsl.component(base_image=BASE_IMAGE, packages_to_install=PACKAGES)
def detect_new_data(bucket: str, prefix: str) -> str:
    """Returns the dataset fingerprint, or "" when it was already trained on."""
    import sys

    sys.path.insert(0, "/testkit")
    import s3

    current = s3.fingerprint(bucket, prefix)
    trained = s3.get_text(bucket, f"{prefix}/_trained_fingerprint")
    print(f"dataset fingerprint={current} last trained={trained or '(never)'}")
    return "" if current == trained else current


@dsl.component(base_image=BASE_IMAGE, packages_to_install=PACKAGES)
def validate_data(bucket: str, prefix: str, dataset: dsl.Output[dsl.Dataset], stats: dsl.Output[dsl.Metrics]):
    import sys

    sys.path.insert(0, "/testkit")
    import pandas as pd
    import s3
    import tabular

    keys = [o["Key"] for o in s3.list_keys(bucket, prefix)]
    df = pd.concat([tabular.from_csv_bytes(s3.get_bytes(bucket, k)) for k in keys], ignore_index=True)
    result = tabular.validate(df)  # raises -> step fails -> pipeline stops
    df.to_csv(dataset.path, index=False)
    dataset.metadata["batches"] = keys
    for k, v in result.items():
        stats.log_metric(k, v)


@dsl.component(base_image=BASE_IMAGE, packages_to_install=PACKAGES)
def train_model(
    dataset: dsl.Input[dsl.Dataset],
    n_estimators: int,
    max_depth: int,
    model: dsl.Output[dsl.Model],
    test_set: dsl.Output[dsl.Dataset],
):
    import os
    import sys

    sys.path.insert(0, "/testkit")
    import joblib
    import pandas as pd
    import tabular

    train_df, test_df = tabular.split(pd.read_csv(dataset.path))
    clf = tabular.train(train_df, n_estimators=n_estimators, max_depth=max_depth)
    os.makedirs(model.path, exist_ok=True)  # KServe's sklearn runtime wants a directory
    joblib.dump(clf, os.path.join(model.path, "model.joblib"))
    model.metadata["framework"] = "sklearn"
    test_df.to_csv(test_set.path, index=False)


@dsl.component(base_image=BASE_IMAGE, packages_to_install=PACKAGES)
def evaluate_model(model: dsl.Input[dsl.Model], test_set: dsl.Input[dsl.Dataset], metrics: dsl.Output[dsl.Metrics]) -> float:
    import os
    import sys

    sys.path.insert(0, "/testkit")
    import joblib
    import pandas as pd
    import tabular

    scores = tabular.evaluate(joblib.load(os.path.join(model.path, "model.joblib")), pd.read_csv(test_set.path))
    for k, v in scores.items():
        metrics.log_metric(k, v)
    return scores["accuracy"]


@dsl.component(base_image=BASE_IMAGE, packages_to_install=["model-registry==0.3.4", "boto3==1.35.99"])
def register_model(
    model: dsl.Input[dsl.Model],
    model_name: str,
    fingerprint: str,
    accuracy: float,
    registry_host: str,
    bucket: str,
    prefix: str,
    run_id: str,
) -> str:
    """Registers a new version in Kubeflow Model Registry; returns the version."""
    import sys

    sys.path.insert(0, "/testkit")
    import s3
    from model_registry import ModelRegistry

    registry = ModelRegistry(server_address=registry_host, port=8080, author="w3-pipeline", is_secure=False)
    try:
        existing = list(registry.get_model_versions(model_name))
    except Exception:
        existing = []
    version = f"v{len(existing) + 1}"
    registry.register_model(
        model_name,
        model.uri,
        version=version,
        model_format_name="sklearn",
        model_format_version="1.6.1",
        description="W3 continuous-training pipeline",
        metadata={"data_fingerprint": fingerprint, "accuracy": accuracy, "kfp_run_id": run_id},
    )
    s3.put_bytes(bucket, f"{prefix}/_trained_fingerprint", fingerprint.encode())
    print(f"registered {model_name} {version} -> {model.uri}")
    return version


@dsl.component(base_image=BASE_IMAGE, packages_to_install=["kubernetes>=26,<31"])
def deploy_model(model: dsl.Input[dsl.Model], model_name: str, version: str, service_account: str):
    """Creates or updates the KServe InferenceService to serve this version."""
    from kubernetes import client, config

    config.load_incluster_config()
    namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
    body = {
        "apiVersion": "serving.kserve.io/v1beta1",
        "kind": "InferenceService",
        "metadata": {
            "name": model_name,
            "annotations": {"sidecar.istio.io/inject": "false"},
            "labels": {"model-version": version},
        },
        "spec": {
            "predictor": {
                "serviceAccountName": service_account,
                "minReplicas": 0,
                "model": {
                    "modelFormat": {"name": "sklearn"},
                    "storageUri": model.uri.replace("minio://", "s3://"),
                    "resources": {"requests": {"cpu": "100m", "memory": "256Mi"}, "limits": {"cpu": "1", "memory": "1Gi"}},
                },
            }
        },
    }
    api = client.CustomObjectsApi()
    args = ("serving.kserve.io", "v1beta1", namespace, "inferenceservices")
    try:
        api.create_namespaced_custom_object(*args, body)
        print("created InferenceService")
    except client.ApiException as e:
        if e.status != 409:
            raise
        api.patch_namespaced_custom_object(*args, model_name, body)
        print("patched InferenceService")


def _wire(task, secret: str = "mlpipeline-minio-artifact"):
    """Test kit on PYTHONPATH, object-store credentials, no result caching."""
    task.set_caching_options(False)
    kubernetes.use_config_map_as_volume(task, config_map_name="testkit", mount_path="/testkit")
    kubernetes.use_secret_as_env(
        task, secret_name=secret, secret_key_to_env={"accesskey": "AWS_ACCESS_KEY_ID", "secretkey": "AWS_SECRET_ACCESS_KEY"}
    )
    task.set_env_variable("S3_ENDPOINT", S3_ENDPOINT)
    return task


@dsl.pipeline(name="w3-continuous-training", description="Validate -> train -> evaluate -> gate -> register -> deploy")
def w3_pipeline(
    bucket: str = "mlpipeline",
    prefix: str = "datasets/w3",
    model_name: str = "sensor-fault",
    accuracy_gate: float = 0.80,
    n_estimators: int = 100,
    max_depth: int = 3,
    registry_host: str = "http://model-registry-service.kubeflow.svc.cluster.local",
    serving_service_account: str = "kserve-s3",
):
    detect = _wire(detect_new_data(bucket=bucket, prefix=prefix))
    with dsl.If(detect.output != "", name="new-data"):
        data = _wire(validate_data(bucket=bucket, prefix=prefix))
        trained = _wire(
            train_model(dataset=data.outputs["dataset"], n_estimators=n_estimators, max_depth=max_depth))
        scored = _wire(
            evaluate_model(model=trained.outputs["model"], test_set=trained.outputs["test_set"]))
        with dsl.If(scored.outputs["Output"] >= accuracy_gate, name="quality-gate"):
            registered = _wire(
                register_model(
                    model=trained.outputs["model"],
                    model_name=model_name,
                    fingerprint=detect.output,
                    accuracy=scored.outputs["Output"],
                    registry_host=registry_host,
                    bucket=bucket,
                    prefix=prefix,
                    run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER,
                ))
            _wire(
                deploy_model(
                    model=trained.outputs["model"],
                    model_name=model_name,
                    version=registered.output,
                    service_account=serving_service_account,
                ))


if __name__ == "__main__":
    import sys

    compiler.Compiler().compile(w3_pipeline, sys.argv[1] if len(sys.argv) > 1 else "w3_pipeline.yaml")

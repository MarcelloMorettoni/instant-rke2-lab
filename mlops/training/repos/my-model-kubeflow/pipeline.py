"""my-model on Kubeflow: the continuous-training pipeline.

  detect change -> validate -> train -> evaluate -> quality gate -> register -> deploy

Each @dsl.component is one step and runs as its own pod. `train_model` is the
step you change in the lesson. Every push to `main` compiles this file and
starts a run (see .gitea/workflows/train.yaml and ci/deploy.py).
"""
import os
import sys

from kfp import compiler, dsl, kubernetes

BASE_IMAGE = "python:3.11-slim"
PACKAGES = ["pandas==2.2.3", "scikit-learn==1.6.1", "boto3==1.35.99", "joblib==1.4.2"]
# Fixed when the pipeline is compiled (KFP only accepts literal env values).
S3_ENDPOINT = "http://minio-service.kubeflow.svc.cluster.local:9000"
LAKEFS_ENDPOINT = "http://lakefs.lakefs.svc.cluster.local"
DATA_STORE = os.environ.get("DATA_STORE", "lakefs")


@dsl.component(base_image=BASE_IMAGE, packages_to_install=PACKAGES)
def detect_change(repository: str, prefix: str, model_name: str, retrain: str) -> str:
    """Returns the data version to train on, or "" when there is nothing to do.

    The data version is the newest lakeFS commit. A run that picks it up marks it
    with a tag tried-<model>-<commit>, so the schedule tries every commit once,
    also when that run fails. retrain=yes trains anyway: CI sets it, because then
    the code changed.
    """
    import sys

    sys.path.insert(0, "/testkit")
    import dataset
    import lakefs

    ds = dataset.Dataset(repository, prefix)
    current = ds.version()
    tried = current in lakefs.tags(repository, f"tried-{model_name}-").values()
    print(f"data {ds.uri(current)} already tried={tried} retrain={retrain}")
    if tried and retrain != "yes":
        return ""
    lakefs.tag(repository, f"tried-{model_name}-{current[:12]}", current)
    return current


@dsl.component(base_image=BASE_IMAGE, packages_to_install=PACKAGES)
def validate_data(repository: str, prefix: str, version: str, dataset: dsl.Output[dsl.Dataset], stats: dsl.Output[dsl.Metrics]):
    """Data quality gate: schema, empty values, class balance, minimum size."""
    import sys

    sys.path.insert(0, "/testkit")
    import dataset as store
    import tabular

    ds = store.Dataset(repository, prefix)
    df, keys = ds.load(version)
    result = tabular.validate(df)  # raises -> the step fails -> the pipeline stops
    df.to_csv(dataset.path, index=False)
    dataset.metadata["files"] = keys
    dataset.metadata["source"] = ds.uri(version)
    for k, v in result.items():
        stats.log_metric(k, v)


@dsl.component(base_image=BASE_IMAGE, packages_to_install=PACKAGES)
def train_model(dataset: dsl.Input[dsl.Dataset], model: dsl.Output[dsl.Model], test_set: dsl.Output[dsl.Dataset]):
    import os

    import joblib
    import pandas as pd
    from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
    from sklearn.model_selection import train_test_split

    features, label = ["temperature", "vibration", "pressure", "current"], "fault"
    df = pd.read_csv(dataset.path)
    train_df, test_df = train_test_split(df, test_size=0.25, random_state=0, stratify=df[label])

    # ---- your training code: this is what you change in the lesson ----
    N_ESTIMATORS = 100
    MAX_DEPTH = 3
    clf = GradientBoostingClassifier(n_estimators=N_ESTIMATORS, max_depth=MAX_DEPTH, random_state=0)
    # -------------------------------------------------------------------

    clf.fit(train_df[features].to_numpy(), train_df[label].to_numpy())
    print(f"trained {clf} on {len(train_df)} rows")
    os.makedirs(model.path, exist_ok=True)  # KServe's sklearn runtime wants a directory
    joblib.dump(clf, os.path.join(model.path, "model.joblib"))
    model.metadata["framework"] = "sklearn"
    model.metadata["algorithm"] = str(clf)
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
    data_version: str,
    accuracy: float,
    git_commit: str,
    repository: str,
    prefix: str,
    run_id: str,
) -> str:
    """New version in Kubeflow Model Registry, with what made it: data, code, run."""
    import sys

    sys.path.insert(0, "/testkit")
    import dataset
    from model_registry import ModelRegistry

    registry = ModelRegistry(
        server_address="http://model-registry-service.kubeflow.svc.cluster.local", port=8080, author="my-model-pipeline", is_secure=False
    )
    try:
        existing = list(registry.get_model_versions(model_name))
    except Exception:
        existing = []
    version = f"v{len(existing) + 1}"
    ds = dataset.Dataset(repository, prefix)
    registry.register_model(
        model_name,
        model.uri,
        version=version,
        model_format_name="sklearn",
        model_format_version="1.6.1",
        description="my-model training pipeline",
        metadata={"accuracy": accuracy, "data_uri": ds.uri(data_version), "git_commit": git_commit, "kfp_run_id": run_id},
    )
    ds.mark_trained(model_name, data_version, version)  # lakeFS tag trained-<model>-<version>
    print(f"registered {model_name} {version} -> {model.uri}")
    return version


@dsl.component(base_image=BASE_IMAGE, packages_to_install=["kubernetes>=26,<31"])
def deploy_model(model: dsl.Input[dsl.Model], model_name: str, version: str):
    """Creates or updates the KServe InferenceService to serve this version."""
    from kubernetes import client, config

    config.load_incluster_config()
    namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
    body = {
        "apiVersion": "serving.kserve.io/v1beta1",
        "kind": "InferenceService",
        "metadata": {"name": model_name, "annotations": {"sidecar.istio.io/inject": "false"}, "labels": {"model-version": version}},
        "spec": {
            "predictor": {
                "serviceAccountName": "kserve-s3",
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


def _wire(task):
    """Lab plumbing for every step: test kit, object-store and lakeFS credentials, no result caching."""
    task.set_caching_options(False)
    kubernetes.use_config_map_as_volume(task, config_map_name="testkit", mount_path="/testkit")
    kubernetes.use_secret_as_env(
        task, secret_name="mlpipeline-minio-artifact", secret_key_to_env={"accesskey": "AWS_ACCESS_KEY_ID", "secretkey": "AWS_SECRET_ACCESS_KEY"}
    )
    kubernetes.use_secret_as_env(
        task,
        secret_name="data-store",
        secret_key_to_env={"LAKEFS_ACCESS_KEY_ID": "LAKEFS_ACCESS_KEY_ID", "LAKEFS_SECRET_ACCESS_KEY": "LAKEFS_SECRET_ACCESS_KEY"},
    )
    task.set_env_variable("S3_ENDPOINT", S3_ENDPOINT)
    task.set_env_variable("DATA_STORE", DATA_STORE)
    task.set_env_variable("LAKEFS_ENDPOINT", LAKEFS_ENDPOINT)
    return task


@dsl.pipeline(name="my-model-training", description="Detect change -> validate -> train -> evaluate -> gate -> register -> deploy")
def my_pipeline(
    repository: str = "kf-my-data",
    prefix: str = "datasets/w3",
    model_name: str = "my-model",
    accuracy_gate: float = 0.80,
    retrain: str = "no",
    git_commit: str = "",
):
    detect = _wire(detect_change(repository=repository, prefix=prefix, model_name=model_name, retrain=retrain))
    with dsl.If(detect.output != "", name="something-changed"):
        data = _wire(validate_data(repository=repository, prefix=prefix, version=detect.output))
        trained = _wire(train_model(dataset=data.outputs["dataset"]))
        scored = _wire(evaluate_model(model=trained.outputs["model"], test_set=trained.outputs["test_set"]))
        with dsl.If(scored.outputs["Output"] >= accuracy_gate, name="quality-gate"):
            registered = _wire(
                register_model(
                    model=trained.outputs["model"],
                    model_name=model_name,
                    data_version=detect.output,
                    accuracy=scored.outputs["Output"],
                    git_commit=git_commit,
                    repository=repository,
                    prefix=prefix,
                    run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER,
                ))
            _wire(deploy_model(model=trained.outputs["model"], model_name=model_name, version=registered.output))


if __name__ == "__main__":
    compiler.Compiler().compile(my_pipeline, sys.argv[1] if len(sys.argv) > 1 else "pipeline.yaml")

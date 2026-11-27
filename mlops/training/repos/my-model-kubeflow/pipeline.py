"""my-model on Kubeflow: two pipelines.

  my-model-training   detect -> validate -> train -> evaluate -> quality gate -> register -> deploy
                      One straight line, so the console shows every step side by side.
  my-model-watch      one step, run every 2 minutes per data branch: when the branch
                      has a new lakeFS commit it starts my-model-training on it.

Each @dsl.component is one step and runs as its own pod. `train_model` is the
step you change in the lesson. Every push to `main` compiles this file and
starts a run (see .gitea/workflows/train.yaml and ci/deploy.py).
"""
import os
import sys
from typing import NamedTuple

from kfp import compiler, dsl, kubernetes

BASE_IMAGE = "python:3.11-slim"
PACKAGES = ["pandas==2.2.3", "scikit-learn==1.6.1", "boto3==1.35.99", "joblib==1.4.2"]
LIGHT = ["boto3==1.35.99"]  # for the steps that only talk to lakeFS
# Fixed when the pipeline is compiled (KFP only accepts literal env values).
S3_ENDPOINT = "http://minio-service.kubeflow.svc.cluster.local:9000"
LAKEFS_ENDPOINT = "http://lakefs.lakefs.svc.cluster.local"
DATA_STORE = os.environ.get("DATA_STORE", "lakefs")


@dsl.component(base_image=BASE_IMAGE, packages_to_install=LIGHT)
def detect_change(
    repository: str, prefix: str, model_name: str, data_branch: str, data_version: str
) -> NamedTuple("Outputs", [("version", str), ("model", str)]):
    """Picks the data to train on and the model it belongs to.

    The data is the lakeFS commit in `data_version`, or the newest commit on
    `data_branch` when that is empty. The commit gets a tag tried-<model>-<commit>,
    which is how the watch pipeline knows not to start it again.

    Every data branch has its own model and endpoint: `main` is <model_name>,
    any other branch is <model_name>-<branch>.
    """
    import re
    import sys
    from collections import namedtuple

    sys.path.insert(0, "/testkit")
    import lakefs

    model = model_name if data_branch == "main" else f"{model_name}-" + re.sub("[^a-z0-9]+", "-", data_branch.lower()).strip("-")
    version = data_version or lakefs.head(repository, data_branch)
    lakefs.tag(repository, f"tried-{model}-{version[:12]}", version)
    print(f"model {model}: training on lakefs://{repository}/{version}/{prefix}/ (branch {data_branch})")
    return namedtuple("Outputs", ["version", "model"])(version, model)


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


@dsl.component(base_image=BASE_IMAGE)
def quality_gate(accuracy: float, minimum: float) -> float:
    """Stops the pipeline when the model is not good enough: this step fails, so nothing is registered or deployed."""
    if accuracy < minimum:
        raise SystemExit(f"quality gate FAILED: accuracy {accuracy:.4f} is below {minimum}; the model is not registered")
    print(f"quality gate passed: accuracy {accuracy:.4f} >= {minimum}")
    return accuracy


@dsl.component(base_image=BASE_IMAGE, packages_to_install=["model-registry==0.3.4", "boto3==1.35.99"])
def register_model(
    model: dsl.Input[dsl.Model],
    model_name: str,
    data_version: str,
    accuracy: float,
    git_commit: str,
    repository: str,
    prefix: str,
    data_branch: str,
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
        metadata={
            "accuracy": accuracy,
            "data_uri": ds.uri(data_version),
            "data_branch": data_branch,
            "git_commit": git_commit,
            "kfp_run_id": run_id,
        },
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
        "metadata": {"name": model_name, "annotations": {"sidecar.istio.io/inject": "false"}, "labels": {"model-version": version, "trained-by": "my-model-training"}},
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


@dsl.component(base_image=BASE_IMAGE, packages_to_install=LIGHT)
def watch_data(
    repository: str, model_name: str, data_branch: str, git_commit: str, experiment_id: str, pipeline_id: str, pipeline_version_id: str
) -> str:
    """The only step of the watch pipeline, which a schedule runs every 2 minutes per data branch.

    New commit on the branch -> starts one run of the training pipeline on exactly
    that commit and returns its name. Nothing new -> returns "". The tag
    tried-<model>-<commit> is set before the run starts, so a commit is tried once,
    also when its training fails.
    """
    import json
    import os
    import re
    import sys
    import urllib.request

    sys.path.insert(0, "/testkit")
    import lakefs

    suffix = "" if data_branch == "main" else "-" + re.sub("[^a-z0-9]+", "-", data_branch.lower()).strip("-")
    model = model_name + suffix
    head = lakefs.head(repository, data_branch)
    if head in lakefs.tags(repository, f"tried-{model}-").values():
        print(f"{model}: branch {data_branch} is still at {head[:12]}, nothing to do")
        return ""
    lakefs.tag(repository, f"tried-{model}-{head[:12]}", head)
    name = f"data-{head[:8]}{suffix}"
    body = {
        "display_name": name,
        "experiment_id": experiment_id,
        "pipeline_version_reference": {"pipeline_id": pipeline_id, "pipeline_version_id": pipeline_version_id},
        "runtime_config": {"parameters": {
            "repository": repository, "model_name": model_name, "data_branch": data_branch, "data_version": head, "git_commit": git_commit,
        }},
    }
    request = urllib.request.Request(
        "http://ml-pipeline.kubeflow.svc.cluster.local:8888/apis/v2beta1/runs",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + open(os.environ["KF_PIPELINES_SA_TOKEN_PATH"]).read()},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        run_id = json.load(response)["run_id"]
    print(f"{model}: new data commit {head[:12]} on branch {data_branch} -> started training run {name} ({run_id})")
    return name


@dsl.pipeline(name="my-model-training", description="detect -> validate -> train -> evaluate -> quality gate -> register -> deploy")
def my_pipeline(
    repository: str = "kf-my-data",
    prefix: str = "datasets/w3",
    model_name: str = "my-model",
    accuracy_gate: float = 0.80,
    git_commit: str = "",
    data_branch: str = "main",
    data_version: str = "",
):
    """One straight line: every step is a box in the graph, and a step that fails stops the ones after it."""
    detect = _wire(detect_change(repository=repository, prefix=prefix, model_name=model_name, data_branch=data_branch, data_version=data_version))
    version, model = detect.outputs["version"], detect.outputs["model"]
    data = _wire(validate_data(repository=repository, prefix=prefix, version=version))
    trained = _wire(train_model(dataset=data.outputs["dataset"]))
    scored = _wire(evaluate_model(model=trained.outputs["model"], test_set=trained.outputs["test_set"]))
    gate = _wire(quality_gate(accuracy=scored.outputs["Output"], minimum=accuracy_gate))
    registered = _wire(
        register_model(
            model=trained.outputs["model"],
            model_name=model,
            data_version=version,
            accuracy=gate.output,  # taking the gate's output makes this step wait for the gate
            git_commit=git_commit,
            repository=repository,
            prefix=prefix,
            data_branch=data_branch,
            run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER,
        )
    )
    _wire(deploy_model(model=trained.outputs["model"], model_name=model, version=registered.output))


@dsl.pipeline(name="my-model-watch", description="Checks one lakeFS branch for a new commit and starts my-model-training on it")
def watch_pipeline(
    experiment_id: str,
    pipeline_id: str,
    pipeline_version_id: str,
    repository: str = "kf-my-data",
    model_name: str = "my-model",
    data_branch: str = "main",
    git_commit: str = "",
):
    watch = _wire(
        watch_data(
            repository=repository, model_name=model_name, data_branch=data_branch, git_commit=git_commit,
            experiment_id=experiment_id, pipeline_id=pipeline_id, pipeline_version_id=pipeline_version_id,
        )
    )
    kubernetes.add_pod_label(watch, "access-ml-pipeline", "true")  # the project's PodDefault then mounts a Pipelines API token


if __name__ == "__main__":
    # python pipeline.py [training.yaml [watch.yaml]]
    compiler.Compiler().compile(my_pipeline, sys.argv[1] if len(sys.argv) > 1 else "pipeline.yaml")
    compiler.Compiler().compile(watch_pipeline, sys.argv[2] if len(sys.argv) > 2 else "watch.yaml")

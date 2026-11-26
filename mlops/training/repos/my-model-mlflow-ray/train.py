"""my-model on MLflow + Ray: search, train, evaluate, gate, register.

Ray Tune tries every combination in SEARCH in parallel on the Ray cluster. Every
trial is an MLflow run. The best model becomes a new version of MODEL in the MLflow
Model Registry, with the alias "champion", only if it passes the accuracy gate.

The pipeline (workflow.yaml) starts this file as a RayJob and sets the
environment variables below.
"""
import os
import sys

import mlflow
import ray
from ray import tune
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier

import dataset
import tabular

MODEL = os.environ["MODEL_NAME"]
GATE = float(os.environ["ACCURACY_GATE"])
ds = dataset.Dataset(os.environ["DATA_REPO"])
VERSION = os.environ.get("DATA_VERSION") or ds.version()
EXPERIMENT = f"{MODEL}-training"
GIT_COMMIT = os.environ.get("GIT_COMMIT", "")

# ---- your training code: this is what you change in the lesson ----
SEARCH = {"n_estimators": tune.grid_search([50, 100]), "max_depth": tune.grid_search([2, 3])}


def build_model(config):
    return GradientBoostingClassifier(n_estimators=config["n_estimators"], max_depth=config["max_depth"], random_state=0)
# -----------------------------------------------------------------


def trial(config):
    train_df, test_df = tabular.split(ray.get(config["data"]))
    model = build_model(config)
    model.fit(train_df[tabular.FEATURES].to_numpy(), train_df[tabular.TARGET].to_numpy())
    scores = tabular.evaluate(model, test_df)
    params = {k: v for k, v in config.items() if k != "data"}
    mlflow.set_experiment(EXPERIMENT)
    with mlflow.start_run(run_name=" ".join(f"{k}={v}" for k, v in params.items())) as run:
        mlflow.log_params({**params, "algorithm": type(model).__name__})
        mlflow.log_metrics(scores)
        mlflow.set_tags({"data_uri": ds.uri(VERSION), "git_commit": GIT_COMMIT, "pipeline": os.environ.get("PIPELINE_RUN", "manual")})
        name, source = ds.catalog(VERSION)
        mlflow.log_input(mlflow.data.from_pandas(train_df, source=source, name=name, digest=VERSION[:16]), context="training")
        mlflow.sklearn.log_model(
            model, name="model", pip_requirements=["scikit-learn==1.6.1"], skops_trusted_types=["sklearn.tree._tree.Tree"]
        )
    tune.report({**scores, "run_id": run.info.run_id})


if __name__ == "__main__":
    ray.init()
    mlflow.set_experiment(EXPERIMENT)  # create it once, before the parallel trials
    df = ds.load(VERSION)[0]
    tabular.validate(df)
    results = tune.Tuner(
        tune.with_resources(trial, {"cpu": 1}),
        param_space={"data": ray.put(df), **SEARCH},
        tune_config=tune.TuneConfig(metric="accuracy", mode="max"),
    ).fit()
    best = results.get_best_result()
    accuracy, run_id = best.metrics["accuracy"], best.metrics["run_id"]
    print(f"best trial: { {k: v for k, v in best.config.items() if k != 'data'} } accuracy={accuracy:.4f}")
    if accuracy < GATE:
        print(f"quality gate FAILED: {accuracy:.4f} < {GATE}; nothing registered")
        sys.exit(2)
    version = mlflow.register_model(f"runs:/{run_id}/model", MODEL, tags={"data_uri": ds.uri(VERSION), "git_commit": GIT_COMMIT, "accuracy": f"{accuracy:.4f}"})
    mlflow.MlflowClient().set_registered_model_alias(MODEL, "champion", version.version)
    ds.mark_trained(MODEL, VERSION, f"v{version.version}")
    print(f"registered {MODEL} version {version.version} as champion (data {ds.uri(VERSION)})")

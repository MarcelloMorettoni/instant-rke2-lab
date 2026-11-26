"""W3 on MLflow + Ray: tune + train + evaluate + gate + register, as one Ray job.

Ray Tune runs a small hyperparameter search in parallel across the cluster,
every trial is an MLflow run, and the best model is registered in the MLflow
Model Registry (alias "champion") only if it passes the accuracy gate.
"""
import os
import sys

import mlflow
import pandas as pd
import ray
from ray import tune

import dataset
import tabular

ds = dataset.Dataset()
MODEL_NAME, EXPERIMENT = "sensor-fault", "w3-continuous-training"
FINGERPRINT = os.environ.get("DATA_FINGERPRINT") or ds.version()
GATE = float(os.environ.get("ACCURACY_GATE", tabular.ACCURACY_GATE))


def load() -> pd.DataFrame:
    return ds.load(FINGERPRINT)[0]


def trial(config):
    train_df, test_df = tabular.split(ray.get(config["data"]))
    model = tabular.train(train_df, n_estimators=config["n_estimators"], max_depth=config["max_depth"])
    scores = tabular.evaluate(model, test_df)
    mlflow.set_experiment(EXPERIMENT)
    with mlflow.start_run(run_name=f"trial-n{config['n_estimators']}-d{config['max_depth']}") as run:
        mlflow.log_params({"n_estimators": config["n_estimators"], "max_depth": config["max_depth"]})
        mlflow.log_metrics(scores)
        mlflow.set_tags({"data_fingerprint": FINGERPRINT, "data_uri": ds.uri(FINGERPRINT), "pipeline": os.environ.get("PIPELINE_RUN", "manual")})
        # Dataset as a first-class MLflow input: this is what a catalog (DataHub)
        # turns into lineage dataset -> run -> model version.
        name, source = ds.catalog(FINGERPRINT)
        mlflow.log_input(mlflow.data.from_pandas(train_df, source=source, name=name, digest=FINGERPRINT[:16]), context="training")
        # MLflow 3.18 saves sklearn models with skops and refuses types it does not
        # know; tree ensembles need this one declared explicitly.
        mlflow.sklearn.log_model(
            model, name="model", pip_requirements=["scikit-learn==1.6.1"], skops_trusted_types=["sklearn.tree._tree.Tree"]
        )
    tune.report({**scores, "run_id": run.info.run_id})


if __name__ == "__main__":
    ray.init()
    # Create the experiment once, here: parallel trials racing to create it hit
    # "403 Permission denied" under MLflow basic auth (permission row not there yet).
    mlflow.set_experiment(EXPERIMENT)
    df = load()
    tabular.validate(df)
    results = tune.Tuner(
        tune.with_resources(trial, {"cpu": 1}),
        param_space={"data": ray.put(df), "n_estimators": tune.grid_search([50, 100]), "max_depth": tune.grid_search([2, 3])},
        tune_config=tune.TuneConfig(metric="accuracy", mode="max"),
    ).fit()
    best = results.get_best_result()
    accuracy, run_id = best.metrics["accuracy"], best.metrics["run_id"]
    print(f"best trial: {best.config['n_estimators']} trees depth {best.config['max_depth']} accuracy={accuracy:.4f}")
    if accuracy < GATE:
        print(f"quality gate FAILED: {accuracy:.4f} < {GATE}; nothing registered")
        sys.exit(2)
    version = mlflow.register_model(f"runs:/{run_id}/model", MODEL_NAME, tags={"data_fingerprint": FINGERPRINT, "data_uri": ds.uri(FINGERPRINT), "accuracy": f"{accuracy:.4f}"})
    mlflow.MlflowClient().set_registered_model_alias(MODEL_NAME, "champion", version.version)
    ds.mark_trained(MODEL_NAME, FINGERPRINT, f"v{version.version}")
    print(f"registered {MODEL_NAME} version {version.version} as champion (fingerprint {FINGERPRINT})")
    with open("/tmp/model_version", "w") as f:
        f.write(str(version.version))

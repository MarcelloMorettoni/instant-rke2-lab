"""Lists the versions of the sensor-fault model in the MLflow Model Registry, with their trial runs."""
import mlflow

client = mlflow.MlflowClient()
for mv in sorted(client.search_model_versions("name='sensor-fault'"), key=lambda v: int(v.version)):
    print(f"version {mv.version} aliases={mv.aliases} run={mv.run_id[:8]} tags={mv.tags}")
champion = client.get_model_version_by_alias("sensor-fault", "champion")
print("champion is version", champion.version)

"""Lists the versions of a model in the MLflow Model Registry.

  mr-kit - < registry.py              the model sensor-fault
  mr-kit - my-model < registry.py     another model
"""
import sys

import mlflow

name = sys.argv[1] if len(sys.argv) > 1 else "sensor-fault"
client = mlflow.MlflowClient()
for mv in sorted(client.search_model_versions(f"name='{name}'"), key=lambda v: int(v.version)):
    print(f"version {mv.version} aliases={mv.aliases} run={mv.run_id[:8]} tags={mv.tags}")
champion = client.get_model_version_by_alias(name, "champion")
print("champion is version", champion.version)

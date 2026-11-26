"""Ray Serve app for the W3 model: serves `models:/sensor-fault@champion` from MLflow.

`user_config.model_version` is bumped by the pipeline's deploy step; Ray Serve
then calls reconfigure() on the running replicas, which reload the champion
without restarting the service.
"""
import mlflow
from ray import serve
from starlette.requests import Request


@serve.deployment(ray_actor_options={"num_cpus": 0.5})
class SensorFault:
    def __init__(self):
        self.model, self.version = None, None

    def reconfigure(self, config: dict):
        client = mlflow.MlflowClient()
        mv = client.get_model_version_by_alias("sensor-fault", "champion")
        self.model, self.version = mlflow.sklearn.load_model(f"models:/sensor-fault/{mv.version}"), mv.version
        print(f"loaded sensor-fault version {mv.version} (requested {config.get('model_version')})")

    async def __call__(self, request: Request):
        body = await request.json()
        return {"predictions": self.model.predict(body["instances"]).tolist(), "model_version": self.version}


app = SensorFault.bind()

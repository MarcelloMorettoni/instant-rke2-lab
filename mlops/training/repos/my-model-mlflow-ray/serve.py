"""Ray Serve app: serves the "champion" version of my-model from MLflow.

The pipeline's deploy step changes `user_config`; Ray Serve then calls
reconfigure() on the running replica, which loads the current champion.
"""
import mlflow
from ray import serve
from starlette.requests import Request

MODEL = "my-model"


@serve.deployment(ray_actor_options={"num_cpus": 0.5})
class MyModel:
    def __init__(self):
        self.model, self.version = None, None

    def reconfigure(self, config: dict):
        mv = mlflow.MlflowClient().get_model_version_by_alias(MODEL, "champion")
        self.model, self.version = mlflow.sklearn.load_model(f"models:/{MODEL}/{mv.version}"), mv.version
        print(f"loaded {MODEL} version {mv.version} (deployed by {config.get('deployed_by')})")

    async def __call__(self, request: Request):
        body = await request.json()
        return {"predictions": self.model.predict(body["instances"]).tolist(), "model_version": self.version}


app = MyModel.bind()

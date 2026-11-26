# my-model on MLflow + Ray

The training code and pipeline of lesson 6 (`mlops/training/06-your-model-mlflow-ray.md`).

| File | What |
|---|---|
| `train.py` | Your training code: Ray Tune search, MLflow tracking, quality gate, registration. |
| `steps.py` | The light pipeline steps: detect a change, validate the data. |
| `serve.py`, `rayservice.yaml` | The endpoint: Ray Serve app that serves the `champion` version. |
| `workflow.yaml` | The pipeline (Argo WorkflowTemplate) and its 2-minute schedule. |
| `ci/deploy.sh` | What CI does on a push: publish code and pipeline, start a run. |
| `.gitea/workflows/train.yaml` | The CI trigger: every push to `main`. |

Push to `main` and watch: **Actions** here, then MLflow.

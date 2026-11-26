# my-model on Kubeflow

The training code and pipeline of lesson 5 (`mlops/training/05-your-model-kubeflow.md`).

| File | What |
|---|---|
| `pipeline.py` | The pipeline. `train_model` is your training code. |
| `ci/deploy.py` | What CI does on a push: compile, upload a new pipeline version, update the schedule, start a run. |
| `.gitea/workflows/train.yaml` | The CI trigger: every push to `main`. |

Push to `main` and watch: **Actions** here, then **Runs** in the Kubeflow console.

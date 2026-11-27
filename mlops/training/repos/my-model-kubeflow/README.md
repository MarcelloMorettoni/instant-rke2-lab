# my-model on Kubeflow

The training code and pipeline of lesson 5 (`mlops/training/05-your-model-kubeflow.md`).

| File | What |
|---|---|
| `pipeline.py` | Two pipelines: `my-model-training` (seven steps in a line; `train_model` is your training code) and `my-model-watch` (starts a training run when a data branch has a new commit). |
| `data-branches.txt` | The lakeFS branches to train on. Each one gets its own model, endpoint and schedule. |
| `ci/deploy.py` | What CI does on a push: compile, upload a new version of both pipelines, start a training run per data branch, schedule the watch. |
| `.gitea/workflows/train.yaml` | The CI trigger: every push to `main`. |

Push to `main` and watch: **Actions** here, then **Runs** in the Kubeflow console.

# Lesson 6: your own model on MLflow + Ray, end to end

The same story as [lesson 5](05-your-model-kubeflow.md), on the other stack:
code in a git repository, data in lakeFS, a pipeline that connects them. You
train a first model, then change the data and the code and watch the pipeline
react. About 60 minutes. The two lessons are independent.

```
 JupyterLab ──git push──▶ Gitea ──CI job──▶ Argo Workflows ──▶ Ray job ──▶ MLflow registry ──▶ Ray Serve endpoint
 (edit code)             (repository)       (pipeline, run,    (search,     (version with git commit
                                             schedule)          train)       and data commit)
 lakeFS console ──commit──▶ lakeFS ◀── the schedule looks every 2 minutes
 (upload data)
```

Do [part 0](README.md#0-start-the-lab) first. Nothing here touches the
`sensor-fault` model of parts 1–4: you get your own data repository
(`mr-my-data`), code repository (`lab/my-model-mlflow-ray`), model (`my-model`)
and endpoint.

| Step | You do | Console | The pipeline |
|---|---|---|---|
| 6.1 | Clone the code | JupyterHub | |
| 6.2 | Create the data | lakeFS | |
| 6.3 | Start the first training | Gitea, then Argo and MLflow | Trains version 1, creates the endpoint |
| 6.4 | Look at the schedule | Argo | Checks for new data every 2 minutes |
| 6.5 | Commit new data | lakeFS | Trains and deploys by itself |
| 6.6 | Push a bad code change | JupyterLab | Trains, then fails at the quality gate |
| 6.7 | Push a good code change | JupyterLab | Trains and deploys |
| 6.8 | Commit broken data | lakeFS | Fails once at validation, endpoint untouched |
| 6.9 | Revert the data | lakeFS | Trains and deploys by itself |
| 6.10 | Trace a model back | all | |

The consoles, all from `mlops/training/lab.sh logins`:

| Console | URL | Login |
|---|---|---|
| JupyterHub | http://localhost:8081 | the account you sign up with |
| Gitea | http://localhost:3000 | `lab` and its password |
| lakeFS | http://localhost:8000 | access key and secret key |
| Argo Workflows | http://localhost:2746/workflows/mr-alpha | none |
| MLflow | http://localhost:5001 | `mr-alpha` and its password |

The Argo console was not part of the POC; I switched it on for this lesson so
this stack has a pipeline view too. It has no login (lab only, reachable on
this desktop). Close its two welcome pop-ups the first time.

## 6.1 Clone the code into a notebook

1. JupyterHub: sign up at http://localhost:8081/hub/signup if you have no
   account (any name, password of 10+ characters), log in, wait for your server.
2. In the launcher open a **Terminal** and clone:

   ```bash
   git clone http://gitea.gitea.svc.cluster.local:3000/lab/my-model-mlflow-ray.git
   ```

3. Open the folder `my-model-mlflow-ray` in the file browser on the left.

This JupyterLab has no Git panel (Kubeflow's notebook image has one), so git
is used from its terminal.

Read the files:

- `train.py`: your training code. It runs as a Ray job: Ray Tune tries every
  combination in `SEARCH` in parallel, each one an MLflow run, and registers
  the best as a new model version if it passes the accuracy gate. The lines
  between the dashed comments are what you change later.
- `steps.py`: the two light steps, detect a change and validate the data.
- `serve.py`, `rayservice.yaml`: the endpoint, a Ray Serve app that serves the
  version carrying the alias `champion`.
- `workflow.yaml`: the pipeline (an Argo `WorkflowTemplate`; the `main`
  template lists the five steps) and its 2-minute schedule.
- `ci/deploy.sh`: what happens on every push. There is no image registry in
  the lab, so "deploying code" means putting these files in a ConfigMap that
  every step mounts, then starting a run.
- `.gitea/workflows/train.yaml`: the trigger, every push to `main`.

## 6.2 Create the data in lakeFS

1. lakeFS → **Create Repository**. Repository ID `mr-my-data`, Storage
   Namespace `s3://lakefs/mr-my-data-1`, **Create Repository**. (Use `-2`,
   `-3`… if you repeat the lesson.)
2. **Upload**. *Common Destination Directory* `datasets/w3/`, file
   `mlops/training/data/batch-001.csv`, **Upload Files**.
3. Green **Commit** button, message `Batch 1`, **Commit**.

<details><summary>The same from the terminal</summary>

```bash
lakectl repo create lakefs://mr-my-data s3://lakefs/mr-my-data-1
```

```bash
lakectl fs upload -s - lakefs://mr-my-data/main/datasets/w3/batch-001.csv < mlops/training/data/batch-001.csv
```

```bash
lakectl commit lakefs://mr-my-data/main -m "Batch 1"
```

</details>

## 6.3 First training

1. Gitea → `lab/my-model-mlflow-ray` → **Actions** → **train** on the left →
   **Run Workflow** → **Run Workflow**.
2. Open the run, the job **publish-and-run**, and the step **Publish code and
   pipeline, start a run**: it created the ConfigMap, the pipeline, the
   schedule, and a workflow `commit-<commit>-<time>`. About a minute.
3. Argo → http://localhost:2746/workflows/mr-alpha → open that workflow. The
   graph fills in top to bottom: `detect`, `validate`, `train` (the Ray job),
   `deploy`, `verify`. Click `detect` or `validate`, then **LOGS**, to read
   its output.
4. MLflow → **Experiments → my-model-training**: four runs appear while `train`
   is running, one per combination. Tick them and **Compare**.

The first run takes about 8 minutes. Most of it is `train` (the Ray cluster
installs its packages) and `verify`, which waits until the new endpoint
answers. A first red `verify(0)` followed by a green `verify(1)` is that wait.

What it produced:

- MLflow → **Models → my-model**: version 1, alias `champion`, with the tags
  `accuracy`, `data_uri` (the lakeFS commit) and `git_commit`. Its source run
  is the winning trial.
- lakeFS → `mr-my-data` → **Commits**: `Batch 1` carries the tags
  `tried-my-model-…` and `trained-my-model-v1`.
- The endpoint:

  ```bash
  mr-kit - my-model < mlops/training/mlflow-ray/predict.py
  ```

  Expected: `status 200`, five predictions and `"model_version":"1"`.

## 6.4 The schedule

Argo → **Cron Workflows** (clock icon in the left bar): `my-ct-every-2min`.
Back under **Workflows** a `my-ct-every-2min-…` run appears every 2 minutes,
about 40 seconds long: `detect` green, the other four skipped. That is the
pipeline saying "nothing new".

## 6.5 Change the data

1. lakeFS → `mr-my-data` → **Upload**, destination `datasets/w3/`, file
   `batch-002.csv`, **Upload Files**.
2. **Commit**, message `Batch 2`.
3. Do nothing else. In Argo the next scheduled workflow runs all five steps
   (about 5 minutes).

MLflow → **Models → my-model**: version 2 is the champion, with another
`data_uri` and a lower accuracy (0.844): the drifted data is harder. The
endpoint reloaded it without a restart:

```bash
mr-kit - my-model < mlops/training/mlflow-ray/predict.py
```

`"model_version":"2"`.

## 6.6 Change the code, badly

In JupyterLab open `train.py` and make the search much too small. Change

```python
SEARCH = {"n_estimators": tune.grid_search([50, 100]), "max_depth": tune.grid_search([2, 3])}
```

to

```python
SEARCH = {"n_estimators": tune.grid_search([5]), "max_depth": tune.grid_search([1])}
```

Save, then in the JupyterLab terminal (the first commit asks you to set a name
and e-mail; the push asks for the Gitea user `lab` and its password):

```bash
cd my-model-mlflow-ray
git config user.name "Your Name"; git config user.email you@lab.invalid
git commit -am "Tiny search"
git push
```

Watch it travel:

1. Gitea → **Actions**: a run with your commit message.
2. Argo: a workflow `commit-<your commit>-…`. The data did not change, but CI
   starts it with `retrain=yes`, so it trains.
3. After about 4 minutes it is red at `train`. Argo only knows that the Ray job
   failed; the reason is in the Ray job's own log:

   ```bash
   kubectl -n $MR logs job/$(kubectl -n $MR get rayjobs --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2) | grep -E "best trial|quality gate"
   ```

   `quality gate FAILED: 0.7560 < 0.8; nothing registered`.

MLflow has the trial (experiment **my-model-training**, run
`n_estimators=5 max_depth=1`, with your `git_commit` as a tag), but **Models →
my-model** still ends at version 2 and the endpoint still serves it.

Compare with lesson 5: there the blocked run was green and you had to open the
graph. Here it is red. Neither is wrong; it is how each pipeline was written.

## 6.7 Change the code, well

Try a different algorithm. In `train.py` replace the two definitions between
the dashed comments with

```python
SEARCH = {"n_estimators": tune.grid_search([100, 200])}


def build_model(config):
    return RandomForestClassifier(n_estimators=config["n_estimators"], random_state=0)
```

```bash
git commit -am "Random forest"
git push
```

Gitea **Actions**, then Argo: this time all five steps (about 5 minutes).

MLflow → **Models → my-model**: version 3 is the champion, with the same
`data_uri` as version 2, your new `git_commit` and a higher accuracy. In the
experiment, **Compare** the runs: the parameter `algorithm` tells the two
kinds apart. That is the advantage over lesson 5: every attempt is a tracked
run, also the rejected one.

## 6.8 Break the data

1. lakeFS → **Upload**, destination `datasets/w3/`, file
   `batch-003-broken.csv`, **Upload Files**.
2. **Commit**, message `Batch 3`.

The next scheduled workflow in Argo is red at `validate`
(`data validation failed: null values present` in its logs). No Ray cluster
was started and the endpoint still serves version 3. The workflows after it are
short and green again: the commit carries a `tried-my-model-…` tag, so it is
tried once.

## 6.9 Fix the data

1. lakeFS → `mr-my-data` → **Commits** → **Revert**.
2. Tick `Batch 3`, **Continue (1)**, **Apply**, **Yes**.

Within 2 minutes a scheduled workflow picks up the revert commit and trains
(about 5 minutes). MLflow → **Models → my-model**: version 4 is the champion.

```bash
mr-kit - my-model < mlops/training/mlflow-ray/predict.py
```

## 6.10 Trace a model back

MLflow → **Models → my-model** → the newest version. Its tags name everything
that made it:

| Tag | Open it in | You find |
|---|---|---|
| `git_commit` | Gitea → `lab/my-model-mlflow-ray` → **Commits** | The exact code |
| `data_uri` | lakeFS → `mr-my-data` → **Commits** | The exact data, tagged `trained-my-model-v…` |
| source run | MLflow | Parameters, metrics, and the tag `pipeline` with the Argo workflow name |

## What you saw

| Change | What started the run | Result |
|---|---|---|
| New data | The schedule | New version, deployed |
| Worse code | Your push | Failed at the quality gate |
| Better code | Your push | New version, deployed |
| Broken data | The schedule | Failed once at validation |
| Data reverted | The schedule | New version, deployed |

Against lesson 5: more pieces to wire (the pipeline is YAML plus scripts, the
console comes from Argo, not from MLflow or Ray), but every training attempt
is in MLflow with its parameters and git commit, and a new version reaches the
endpoint without restarting it.

## Clean up

The schedule starts a pod every 2 minutes and the endpoint holds 0.5 CPU and
2 GiB. This removes both, with the pipeline, the model `my-model` in MLflow
and the data repository, and puts the git repository back to its starting
point:

```bash
mlops/training/lab.sh reset
```

Delete the folder `my-model-mlflow-ray` in JupyterLab before you do the lesson
again, and clone it fresh.

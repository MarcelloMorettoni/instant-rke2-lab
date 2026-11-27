# Lesson 5: your own model on Kubeflow, end to end

One story, done in the web consoles: your code lives in a git repository, your
data in lakeFS, and a pipeline connects them. You train a first model, then
change the data and the code and watch the pipeline react each time. About 60
minutes, most of it watching runs.

```
 JupyterLab ──git push──▶ Gitea ──CI job──▶ Kubeflow Pipelines ──▶ Model Registry ──▶ KServe endpoint
 (edit code)             (repository)       (pipeline version,       (version with git commit
                                             run, schedule)           and data commit)
 lakeFS console ──commit──▶ lakeFS ◀── the schedule looks every 2 minutes
 (upload data)
```

Do [part 0](README.md#0-start-the-lab) first. Nothing here touches the
`sensor-fault` model of parts 1–4: you get your own data repository
(`kf-my-data`), code repository (`lab/my-model-kubeflow`), model (`my-model`)
and endpoint.

| Step | You do | Console | The pipeline |
|---|---|---|---|
| 5.1 | Clone the code | Kubeflow notebook | |
| 5.2 | Create the data | lakeFS | |
| 5.3 | Start the first training | Gitea, then Kubeflow | Trains the first version, creates the endpoint |
| 5.4 | Look at the schedule | Kubeflow | Checks for new data every 2 minutes |
| 5.5 | Commit new data | lakeFS | Trains and deploys by itself |
| 5.6 | Push a bad code change | JupyterLab | Trains, then the quality gate blocks it |
| 5.7 | Push a good code change | JupyterLab | Trains and deploys |
| 5.8 | Commit broken data | lakeFS | Fails once at validation, endpoint untouched |
| 5.9 | Revert the data | lakeFS | Trains and deploys by itself |
| 5.10 | Trace a model back | all | |
| 5.11 | Add a second data branch | lakeFS, JupyterLab | Trains and serves one model per branch |

The consoles, all from `mlops/training/lab.sh logins`:

| Console | URL | Login |
|---|---|---|
| Kubeflow | http://localhost:8080 | `user@example.com` / `12341234` |
| Gitea | http://localhost:3000 | `lab` and its password |
| lakeFS | http://localhost:8000 | access key and secret key |

## 5.1 Clone the code into a notebook

1. Kubeflow → **Notebooks**. Use a notebook you have, or **New Notebook**:
   give it a name, leave the rest, **Launch**, wait for the green tick.
2. **Connect** opens JupyterLab.
3. Menu **Git → Clone a Repository** and paste:

   ```
   http://gitea.gitea.svc.cluster.local:3000/lab/my-model-kubeflow.git
   ```

   (Or open a **Terminal** from the launcher and run `git clone` with that URL.)
4. Open the folder `my-model-kubeflow` in the file browser on the left.

Read three files:

- `pipeline.py`: the pipeline. Each `@dsl.component` is one step.
  `train_model` holds your training code: the three lines between the dashed
  comments are what you change later. At the bottom are two pipelines.
  `my_pipeline` is the training pipeline: seven steps in one straight line,
  where a step that fails stops the ones after it. `watch_pipeline` has one
  step, which looks for a new data commit and then starts the training
  pipeline.
- `ci/deploy.py`: what happens on every push. It compiles `pipeline.py`,
  uploads both pipelines to Kubeflow Pipelines as a new version named after
  the git commit, starts a training run, and schedules the watch pipeline.
- `.gitea/workflows/train.yaml`: the trigger. Every push to `main` runs
  `ci/deploy.py` in a small CI pod inside your Kubeflow project.

The same repository in the Gitea console: http://localhost:3000/lab/my-model-kubeflow.

## 5.2 Create the data in lakeFS

The batches are CSV files in this repository, under
[data/](data/): `batch-001.csv`, `batch-002.csv`, `batch-003-broken.csv`.

1. lakeFS → **Create Repository**. Repository ID `kf-my-data`, Storage
   Namespace `s3://lakefs/kf-my-data-1`, then **Create Repository**. (lakeFS
   never reuses a storage namespace: if you repeat the lesson, use `-2`, `-3`…)
2. In the new repository: **Upload**. In *Common Destination Directory* type
   `datasets/w3/`, choose `mlops/training/data/batch-001.csv`, **Upload Files**.
3. The file shows as an uncommitted change. Click the green **Commit** button,
   message `Batch 1`, **Commit**.

Nothing trains yet: there is no pipeline until the first CI run.

<details><summary>The same from the terminal</summary>

```bash
lakectl repo create lakefs://kf-my-data s3://lakefs/kf-my-data-1
```

```bash
lakectl fs upload -s - lakefs://kf-my-data/main/datasets/w3/batch-001.csv < mlops/training/data/batch-001.csv
```

```bash
lakectl commit lakefs://kf-my-data/main -m "Batch 1"
```

</details>

## 5.3 First training

1. Gitea → `lab/my-model-kubeflow` → **Actions** → **train** on the left →
   **Run Workflow** → **Run Workflow**.
2. A run appears in the list. Open it, click the job **publish-and-run**, and
   open the step **Compile, upload, schedule, run** to read its log: a new
   pipeline version `commit-…`, a run started, the schedule created. The job
   takes about a minute.
3. Kubeflow → **Runs**: a run named `commit-<first 8 characters of the commit>`.
   Open it. The graph is one line of seven steps, each turning green in
   turn: `detect-change`, `validate-data`, `train-model`, `evaluate-model`,
   `quality-gate`, `register-model`, `deploy-model`.
4. Click a step while it runs: **Logs** shows its output, **Input/Output** its
   artifacts. On `evaluate-model`, **Output Parameters** is the accuracy.

The run takes about 6 minutes: each step is a pod that installs its packages
first.

What it produced:

- Kubeflow → **Pipelines**: `my-model-training` and `my-model-watch`, each
  with one version per commit.
- Kubeflow → **KServe Endpoints**: `my-model`.
- lakeFS → `kf-my-data` → **Commits**: the commit `Batch 1` now carries two
  tags, `tried-my-model-…` (a run picked it up) and `trained-my-model-v…` (a
  model version was trained on it).
- The model version. Kubeflow → **Model Registry** → `my-model` → the newest
  version shows its properties. The same from the terminal:

  ```bash
  kf-kit - my-model < mlops/training/kubeflow/registry.py
  ```

  The newest `VERSION` line has `accuracy` 0.888, `data_uri` (the lakeFS
  commit), `git_commit` and `kfp_run_id`. The registry cannot delete, and my
  test runs used v1 to v8, so your first version is `v9`.

Ask the endpoint for five predictions:

```bash
kf-kit - my-model < mlops/training/kubeflow/predict.py
```

Expected: `status 200`, and `predicted` mostly equal to `expected`.

## 5.4 The schedule

Kubeflow → **Recurring Runs**: `my-model-watch-data`, `ENABLED`, every 2
minutes. CI created it. Kubeflow Pipelines has no "run when data arrives", so
the schedule runs the small pipeline `my-model-watch`: its one step,
`watch-data`, asks lakeFS for the newest commit on the branch. If that commit
was not tried yet, the step starts a run of `my-model-training` on it.

Back in **Runs** you see one `my-model-watch-data…` run every 2 minutes, each
under a minute, a single green box. Open one and read the **Logs** of
`watch-data`: `nothing to do`.

## 5.5 Change the data

New readings arrive, and the sensors have drifted.

1. lakeFS → `kf-my-data` → **Upload**, destination `datasets/w3/`, file
   `batch-002.csv`, **Upload Files**.
2. **Commit**, message `Batch 2`.
3. Do nothing else. Kubeflow → **Runs**: within 2 minutes a new run appears,
   named `data-<first 8 characters of the lakeFS commit>`. The watch step
   started it; its log says so. Open the run and watch the seven steps.

About 5 minutes later:

```bash
kf-kit - my-model < mlops/training/kubeflow/registry.py | grep VERSION | tail -1
```

A new version with another `data_uri` and a lower accuracy (0.840): the
drifted data is harder. It passed the gate (0.80), so **KServe Endpoints**
shows `my-model` on a new revision. You only committed data.

## 5.6 Change the code, badly

In JupyterLab open `pipeline.py` and make the model much too simple. Change

```python
    N_ESTIMATORS = 100
    MAX_DEPTH = 3
```

to

```python
    N_ESTIMATORS = 5
    MAX_DEPTH = 1
```

Save (Ctrl-S). Then commit and push from the **Git** panel (the diamond icon
in the left bar):

1. `pipeline.py` is under **Changed**. Hover it and click **+** to stage it.
2. Type a summary, for example `Smaller model`, and click **Commit**. The first
   time it asks who is committing: any name and e-mail.
3. Click the **push** icon at the top of the panel (cloud with an arrow up).
   Enter the Gitea user `lab` and its password. *Successfully pushed* appears
   bottom right.

Now watch it travel:

1. Gitea → **Actions**: a run with your commit message.
2. Kubeflow → **Runs**: `commit-<your commit>`. The data did not change, but
   the code did, so CI starts a training run.
3. After about 4 minutes the run is red, at `quality-gate`. Its **Logs** end
   with `quality gate FAILED: accuracy 0.7560 is below 0.8`. `register-model`
   and `deploy-model` never started.

```bash
kf-kit - my-model < mlops/training/kubeflow/registry.py | grep -c VERSION
```

The same number of versions as before, and the endpoint is unchanged. The gate
kept a bad model out of production, and the red run in the list tells you so
without opening anything.

## 5.7 Change the code, well

Try a different algorithm. In `pipeline.py` replace the line

```python
    clf = GradientBoostingClassifier(n_estimators=N_ESTIMATORS, max_depth=MAX_DEPTH, random_state=0)
```

with

```python
    clf = RandomForestClassifier(n_estimators=200, random_state=0)
```

Save, stage, commit (`Random forest`), push. Same path: Gitea **Actions**,
then Kubeflow **Runs** → `commit-<your commit>`, this time through all seven
steps (about 5 minutes).

```bash
kf-kit - my-model < mlops/training/kubeflow/registry.py | grep VERSION | tail -2
```

The newest version has the same `data_uri` as the one before it, a different
`git_commit`, and a higher accuracy (0.864). Same data, better code.

Kubeflow → **Recurring Runs** now lists `my-model-watch-data` twice: the
`DISABLED` one used the previous pipeline version, the `ENABLED` one uses your
commit. The schedule always runs the code you pushed last.

## 5.8 Break the data

A sensor fails: 50 temperature readings are empty.

1. lakeFS → **Upload**, destination `datasets/w3/`, file
   `batch-003-broken.csv`, **Upload Files**.
2. **Commit**, message `Batch 3`.

Within 2 minutes a run `data-<commit>` appears and turns red at
`validate-data`. Its **Logs** end with `data validation failed: null values
present`. Nothing was trained; the endpoint still serves the previous version.

The watch runs after it say `nothing to do` again: the commit carries a
`tried-my-model-…` tag, so it is not started a second time. One red run per
bad commit, not one every two minutes.

## 5.9 Fix the data

Undo the bad commit the lakeFS way:

1. lakeFS → `kf-my-data` → **Commits** → **Revert**.
2. Tick `Batch 3`, **Continue (1)**, **Apply**, **Yes**.

A new commit `Revert commit …` is on top. Do nothing else: within 2 minutes
the watch starts a run `data-<commit>` for it, which trains (about 5 minutes).

```bash
kf-kit - my-model < mlops/training/kubeflow/registry.py | grep VERSION | tail -1
```

A new version. Its data is what it was before the broken batch, under a new
commit ID: the pipeline compares commits, not content.

## 5.10 Trace a model back

Take the newest `VERSION` line from the registry. Everything that made it is
in three fields:

| Field | Open it in | You find |
|---|---|---|
| `git_commit` | Gitea → `lab/my-model-kubeflow` → **Commits** | The exact code, and who pushed it |
| `data_uri` | lakeFS → `kf-my-data` → **Commits** | The exact data; the commit also carries the tag `trained-my-model-v…` |
| `kfp_run_id` | Kubeflow → **Runs** | The run, its logs, the accuracy |

That is the end-to-end chain: a change in git or in lakeFS becomes a model
version that names both.

## 5.11 Two data branches, two models, both served

lakeFS branches let you keep two variants of the data side by side. The
pipeline has a parameter `data_branch`, and every branch gets its own model:
`main` trains `my-model`, a branch `experiment` trains `my-model-experiment`.
Each has its own versions in the Model Registry, its own endpoint and its own
2-minute schedule.

1. Make the branch and put different data on it. In the lakeFS console:
   `kf-my-data` → **Branches** → **Create Branch**, name `experiment`, from
   `main`; then switch to it in **Objects**, upload a changed file to
   `datasets/w3/` and **Commit**. Or from a notebook:

   ```python
   exp = repo.branch("experiment").create(source_reference="main")
   clean = df[df.temperature.abs() < 1.0]
   exp.object("datasets/w3/batch-001.csv").upload(data=clean.to_csv(index=False), mode="w")
   exp.commit(message="Keep readings within 1 standard deviation")
   ```

   A branch needs at least 200 rows and both classes, or the run stops at
   `validate-data`.

2. Tell the pipeline about the branch. In JupyterLab open
   `data-branches.txt` in your clone, add a line `experiment` under `main`,
   save, and commit and push it from the Git panel (message `Train on the
   experiment branch too`).

3. Gitea → **Actions**: the job now starts two runs. Kubeflow → **Runs**:
   `commit-<commit>` (branch `main`) and `commit-<commit>-experiment`. Open
   both graphs; the log of `detect-change` names the branch, the commit and
   the model.
   About 6 minutes for the pair.

4. Kubeflow → **Recurring Runs**: `my-model-watch-data` and
   `my-model-watch-data-experiment`. From now on a commit on either branch
   retrains only that branch's model.

Both models, with the branch and commit each was trained on:

```bash
kf-kit - my-model < mlops/training/kubeflow/registry.py
```

```bash
kf-kit - my-model-experiment < mlops/training/kubeflow/registry.py
```

Both endpoints (Kubeflow → **KServe Endpoints** lists them):

```bash
kf-kit - my-model < mlops/training/kubeflow/predict.py
```

```bash
kf-kit - my-model-experiment < mlops/training/kubeflow/predict.py
```

To train a branch once without a schedule, skip step 2: Kubeflow → **Runs**
→ **Create run**, pipeline `my-model-training`, experiment `my-model`, and
set the run parameter `data_branch`.

To stop training a branch, remove its line and push: its schedule goes, the
model and endpoint stay. Merging `experiment` into `main` in lakeFS is a new
commit on `main`, so `my-model` retrains on the merged data by itself.

## What you saw

| Change | What started the run | Result |
|---|---|---|
| New data | The schedule | New version, deployed |
| Worse code | Your push | Stopped at the quality gate |
| Better code | Your push | New version, deployed |
| Broken data | The schedule | Failed once at validation |
| Data reverted | The schedule | New version, deployed |

What is built in and what the lab added: Kubeflow gave the pipeline engine, the
run graph, the schedule and the endpoint. Git, the CI trigger and the data
versioning are separate tools (Gitea, lakeFS) wired in by `ci/deploy.py` and
`pipeline.py`. Kubeflow has no git or data trigger of its own.

## Clean up

The schedule starts a pod every 2 minutes until you stop it. This removes it,
together with the pipeline, the endpoint and the data repository, and puts the
git repository back to its starting point:

```bash
mlops/training/lab.sh reset
```

Delete the folder `my-model-kubeflow` in JupyterLab before you do the lesson
again, and clone it fresh. Model versions stay in the Model Registry.

Next: the same story on the other stack, [lesson 6](06-your-model-mlflow-ray.md).

# Part 3: lakeFS

lakeFS puts Git-style versions on top of the object store: commits, branches,
tags, merge, revert. In this lab it closes the "① Data: version" step for both
stacks. Do [part 0](README.md#0-start-the-lab) first. Run commands from the
repository root.

| Step | What you learn |
|---|---|
| 3.1 | The UI and the three existing repositories |
| 3.2 | Commit, branch, diff, merge, tag, revert in your own repository |
| 3.3 | New data → new model on Kubeflow |
| 3.4 | New data → new model on MLflow + Ray |
| 3.5 | Read back the exact dataset of an old model |
| 3.6 | Optional: let a schedule retrain by itself |

## 3.1 Look around

1. Open http://localhost:8000 and log in with the access key and secret key
   from `mlops/training/lab.sh logins`.
2. Three repositories: `kf-sensor-data` (Kubeflow project), `mr-sensor-data`
   (MLflow + Ray project), `smoke` (my test).
3. Open `mr-sensor-data` → `datasets/w3/`: the CSV batches the pipeline trains on.
4. **Commits**: one commit per batch added. **Tags**: `trained-sensor-fault-v…`,
   one per model version; the pipeline creates them.

The same from the terminal:

```bash
lakectl repo list
```

```bash
lakectl log lakefs://mr-sensor-data/main --amount 3
```

```bash
lakectl tag list lakefs://mr-sensor-data
```

What to notice: there is one login, the admin key. The open-source edition has
no second user, so this instance cannot separate projects.

## 3.2 The basics, in your own repository

Create a repository. Its files go to a new folder in the bucket `lakefs` on the lab's object
store (lakeFS refuses to reuse a folder, hence the timestamp).

```bash
lakectl repo create lakefs://training s3://lakefs/training-$(date +%s)
```

Upload a file to `main` and commit it. Until the commit, the file is an
uncommitted change on the branch.

```bash
printf 'sensor,temperature\na,20.5\nb,21.0\n' | lakectl fs upload -s - lakefs://training/main/data/readings.csv
```

```bash
lakectl commit lakefs://training/main -m "First readings"
```

Branch. A branch is free: no data is copied.

```bash
lakectl branch create lakefs://training/experiment -s lakefs://training/main
```

Put a bad value on the branch (sensor `c` at 999 degrees):

```bash
printf 'sensor,temperature\na,20.5\nb,21.0\nc,999\n' | lakectl fs upload -s - lakefs://training/experiment/data/readings.csv
```

See the uncommitted change, commit it, then compare the branches:

```bash
lakectl diff lakefs://training/experiment
```

```bash
lakectl commit lakefs://training/experiment -m "Add sensor c"
```

```bash
lakectl diff lakefs://training/main lakefs://training/experiment
```

`main` is untouched. This is how you test new data without risk:

```bash
lakectl fs cat lakefs://training/main/data/readings.csv
```

Merge the branch, then tag the result:

```bash
lakectl merge lakefs://training/experiment lakefs://training/main
```

```bash
lakectl tag create lakefs://training/with-sensor-c lakefs://training/main
```

Now the bad value is on `main`. Undo the merge (`--parent-number 1` keeps the
`main` side of the merge):

```bash
lakectl branch revert lakefs://training/main main --parent-number 1 --yes
```

`main` is clean again, and the tagged state is still readable:

```bash
lakectl fs cat lakefs://training/main/data/readings.csv
```

```bash
lakectl fs cat lakefs://training/with-sensor-c/data/readings.csv
```

```bash
lakectl log lakefs://training/main --amount 4
```

In the UI, open `training`: **Branches**, **Commits**, **Tags**, and
**Compare** show the same story.

Programs do not need lakectl. lakeFS speaks the S3 protocol, with the
repository as the bucket and the branch, tag or commit as the first folder:

```bash
mr-kit -c "
import lakefs
print(lakefs.list_keys('training', 'main', 'data/'))
print(lakefs.list_keys('training', 'with-sensor-c', 'data/'))"
```

That is why the pipelines needed only small changes to read from lakeFS
([testkit/lakefs.py](../testkit/lakefs.py), [testkit/dataset.py](../testkit/dataset.py)).

## 3.3 New data → new model on Kubeflow

The pipeline's first step asks lakeFS for the newest commit on `main` and checks
whether a tag `trained-sensor-fault-*` already points to it. If yes, it stops.
In 1.7 you saw it stop. Now give it something new.

Add a batch and commit it (the number names the file; use a new one each time):

```bash
kf-kit - 21 < mlops/training/add_batch.py
```

Expected: `version before` and `version after` are two different commit IDs.

Run the pipeline (compile first if you skipped 1.7 or the pod restarted, see
[1.7](01-kubeflow.md#17-the-real-pipeline-validate-train-evaluate-gate-register-deploy)):

```bash
kf-kit /workloads/kfp_cli.py run /tmp/w3_pipeline.yaml my-new-data-run bucket=kf-sensor-data
```

Expected after about 5 minutes: `state=SUCCEEDED` with `validate-data`,
`train-model`, `evaluate-model`, `register-model` and `deploy-model`. Watch the
graph fill in under **Runs** in the Kubeflow UI while you wait.

Check the result:

```bash
kf-kit - < mlops/training/kubeflow/registry.py | grep -A1 "VERSION v" | tail -2
```

The newest version carries `data_uri: lakefs://kf-sensor-data/<commit>/…`: the
`version after` from above.

```bash
lakectl tag list lakefs://kf-sensor-data
```

A new tag `trained-sensor-fault-v…` points to the same commit. Model and data
now reference each other.

## 3.4 New data → new model on MLflow + Ray

Same exercise, other stack.

```bash
mr-kit - 21 < mlops/training/add_batch.py
```

```bash
mlops/mlflow-ray/workloads/run-workflow.sh $MR my-new-data-run
```

Expected after 4–5 minutes: `phase=Succeeded` and all five steps `Succeeded`
(detect, validate, train, deploy, verify).

```bash
mr-kit - < mlops/training/mlflow-ray/registry.py | tail -2
```

```bash
lakectl tag list lakefs://mr-sensor-data
```

The endpoint was redeployed by the pipeline, so it already serves the new version:

```bash
mr-kit - < mlops/training/mlflow-ray/predict.py
```

In MLflow (http://localhost:5001 → **Models → sensor-fault** → newest version →
its source run): tag `data_uri` and the **Datasets used** entry name the commit.
Part 4 turns that entry into lineage.

## 3.5 Read back what an old model was trained on

The reason to version data: months later, you can load exactly the rows behind
any model version.

```bash
kf-kit - < mlops/training/dataset_of_model.py
```

```bash
mr-kit - < mlops/training/dataset_of_model.py
```

Expected: one line per trained model version, with a growing number of files
and rows (500 rows per batch). Without lakeFS only the current state of the
bucket could be read.

## 3.6 Optional: retrain on a schedule

Neither stack reacts to a data event; both poll. This turns the 2-minute
schedule on for the MLflow + Ray project.

```bash
kubectl -n $MR patch cronworkflow w3-ct-every-2min --type=merge -p '{"spec":{"suspend":false}}'
```

Add data, then watch workflows appear. The first one after your commit trains;
later ones skip in 40 s.

```bash
mr-kit - 22 < mlops/training/add_batch.py
```

```bash
kubectl -n $MR get workflows --sort-by=.metadata.creationTimestamp -w
```

When a new model version shows up (`mr-kit - < mlops/training/mlflow-ray/registry.py | tail -2`),
**turn the schedule off again**, or it keeps starting a pod every two minutes:

```bash
kubectl -n $MR patch cronworkflow w3-ct-every-2min --type=merge -p '{"spec":{"suspend":true}}'
```

The Kubeflow equivalent is a recurring run (**Recurring Runs** in the UI):

```bash
kf-kit /workloads/kfp_cli.py schedule /tmp/w3_pipeline.yaml every-2-min "0 */2 * * * *" bucket=kf-sensor-data
```

```bash
kf-kit /workloads/kfp_cli.py unschedule
```

## What you used

| You did | lakeFS feature |
|---|---|
| Isolated a bad batch | Branch |
| Undid a merge | Revert |
| Named a state | Tag |
| Trained on an exact state | Commit ID as the dataset version |
| Linked model and data | Tag per model version, `data_uri` on the model |

Limits to remember: one user in the open-source edition, and no data-event
trigger for the pipelines (lakeFS hooks could provide one; not tested).

Next: [Part 4: DataHub](04-datahub.md).

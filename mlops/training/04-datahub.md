# Part 4: DataHub

DataHub is a catalog. It stores no data and versions nothing; it collects
*descriptions* of what other systems hold and lets people search them, see who
owns them and how they depend on each other. Do
[part 0](README.md#0-start-the-lab) first, and ideally
[3.4](03-lakefs.md#34-new-data--new-model-on-mlflow--ray), so there is a fresh
model to find. Run commands from the repository root.

| Step | What you learn |
|---|---|
| 4.0 | Start DataHub |
| 4.1 | Search and browse |
| 4.2 | Ingestion: how metadata gets in |
| 4.3 | Lineage from a model version back to its dataset |
| 4.4 | Ownership, tags and documentation |
| 4.5 | What the catalog cannot see |

## 4.0 Start DataHub

It is paused to leave room for the training jobs (7 pods, about 3.7 GiB).

```bash
mlops/training/lab.sh resume-datahub
```

This waits until every pod is ready, 3 to 5 minutes. Then:

```bash
mlops/training/lab.sh status
```

The ingestion pod reinstalls its tools after a restart. Wait for it:

```bash
kubectl -n datahub wait --for=condition=Ready pod -l app=ingest --timeout=10m
```

## 4.1 Search and browse

1. Open http://localhost:9002 and log in with `datahub` / `datahub`. That
   default login working after install is one of the findings.
2. Type `sensor` in the search bar. You get the model group `sensor-fault`, its
   versions (`sensor-fault_1`, `sensor-fault_2`, …) and two datasets.
3. Use the filters on the left: **Platform** separates MLflow from S3,
   **Type** separates models from datasets.
4. Open the dataset `mr-sensor-data/main/datasets/w3` on platform **S3**. The
   **Columns** tab lists the five columns DataHub read from the CSV files
   through the lakeFS gateway.
5. Open the model group **sensor-fault**: its versions, and under
   **Properties** what MLflow knows about each.

## 4.2 Ingestion

Metadata gets in through *recipes*: a source, its settings and a sink. Read the
two used here: [datahub/recipes/mlflow.yml](../datahub/recipes/mlflow.yml) and
[datahub/recipes/lakefs-s3.yml](../datahub/recipes/lakefs-s3.yml).

Pull models, versions and runs from MLflow:

```bash
datahub-ingest mlops/datahub/recipes/mlflow.yml | tail -4
```

Pull the datasets from lakeFS. There is no lakeFS source, so the generic S3
source reads the lakeFS gateway:

```bash
datahub-ingest mlops/datahub/recipes/lakefs-s3.yml | tail -4
```

Expected for both: `Pipeline finished successfully`, with no failures.

Search `sensor` again: the model version you trained in 3.4 is now there.

The same lookup from the terminal:

```bash
datahub get --urn "urn:li:mlModelGroup:(urn:li:dataPlatform:mlflow,sensor-fault,PROD)" | head -30
```

In production these recipes run on a schedule (from the DataHub UI under
**Data Sources**, or from a cron job). Here you start them by hand; scheduled
ingestion was not tested.

## 4.3 Lineage: from a model back to its data

The question a catalog should answer: *which data was this model trained on?*

1. In the UI open the newest model version, `sensor-fault_<n>`.
2. Open the **Lineage** tab and switch to the graph view.
3. Follow it upstream: model version ← training run ← MLflow dataset ← the S3
   dataset `mr-sensor-data/main/datasets/w3`.

The same from the terminal (replace 7 by your newest version number):

```bash
datahub-py - 7 < mlops/training/datahub/lineage.py
```

Expected: three upstream entities, one, two and three steps back: a training
run, the MLflow dataset and the S3 dataset.

Now try version 5:

```bash
datahub-py - 5 < mlops/training/datahub/lineage.py
```

Only the training run: no dataset. That version was trained before the
training script logged its dataset with `mlflow.log_input` (four lines in
[mlflow-ray/workloads/w3_ray_train.py](../mlflow-ray/workloads/w3_ray_train.py)).
Lineage is only as good as what the tools upstream record.

Where the exact data version is: open the training run in MLflow; its dataset
source is `s3://mr-sensor-data/<commit>/…`. DataHub shows the dataset as the
branch `main`, not the commit. For the commit you still go to MLflow or lakeFS.

## 4.4 Ownership, tags and documentation

This is what a catalog adds that none of the other tools has. On the dataset
`mr-sensor-data/main/datasets/w3`:

1. **Owners → Add Owners**: choose `datahub`, type *Technical Owner*.
2. **Tags → Add Tags**: create a tag `training`.
3. **Documentation → Add Documentation**: write two lines on what the data is
   (sensor readings, 500 rows per batch, label column `fault`).
4. On the **Columns** tab, add a description to the column `fault`.

Now search for `tag:training`, or type a word from your documentation in the
search bar: the dataset is found by what you wrote.

Run the lakeFS recipe again and check your edits are still there. Ingestion
updates what the source knows and leaves what people added.

```bash
datahub-ingest mlops/datahub/recipes/lakefs-s3.yml | tail -2
```

## 4.5 What the catalog cannot see

- Search for `kubeflow`: nothing from Kubeflow comes back. DataHub 1.9 has no
  Kubeflow source, so Kubeflow's Model Registry and pipelines are invisible
  unless we write an emitter. (The model `smollm2-135m-shakespeare` you may
  find is the copy the Ray job registered in MLflow.)
- The dataset `kf-sensor-data/main/datasets/w3` is there (it came through the
  lakeFS gateway), but nothing links it to a Kubeflow model.
- lakeFS commits, branches and tags do not appear: a branch is a folder to the
  S3 source.

## When you are done

Pause DataHub again if you go back to parts 1–3:

```bash
mlops/training/lab.sh pause-datahub
```

## What you used

| You did | DataHub feature |
|---|---|
| Found models and datasets across tools | Search and filters |
| Loaded metadata | Ingestion recipes (MLflow, S3) |
| Traced a model to its data | Lineage |
| Named an owner, tagged, documented | Governance metadata |

The cost to remember: 7 pods with their own MySQL, OpenSearch and Kafka, more
than the whole MLflow + Ray core.

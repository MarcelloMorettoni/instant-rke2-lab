# Add-on test: lakeFS (data versioning) + DataHub (catalog)

> Status: DRAFT · Tested: 26 Nov 2026 · Same lab cluster as the two candidate pages
> Companion to [Kubeflow](kubeflow.md), [MLflow + Ray](mlflow-ray.md) and the [comparison](comparison.md).
> This is not a candidate, so it does not use the candidate template; it answers one question: can the Data-stage gap be closed, and does it favour either candidate?

## Bottom line

- **lakeFS closes the data-versioning gap for both candidates, with very little work.** W3 ran unchanged in structure on both: the pipeline now trains on a commit id, tags that commit with the model version, and every trained dataset state can be read back. Two pods, 26 s to install.
- **The open-source edition of lakeFS has one user.** There are no groups, policies or second users, so it cannot isolate projects. That is the condition attached to it: one instance per project, or the paid edition.
- **DataHub works, but only for MLflow + Ray.** It ingested MLflow's models, versions and runs, and showed lineage from a model version back to the lakeFS dataset. It has no source for Kubeflow, so Kubeflow's Model Registry and pipelines stay outside the catalog unless we write an emitter.
- **DataHub is a platform of its own**: 6 pods, about 3.7 GiB in use at idle, three stateful services. That is larger than the whole MLflow + Ray core.

Recommendation: adopt lakeFS-style versioning in the pilot for either candidate, after settling the multi-user question. Treat DataHub as optional, to be added only when findability across groups is a real requirement; it does not change the choice between the candidates, but it fits MLflow + Ray with no extra code and Kubeflow only with custom work.

## What was installed

| | lakeFS | DataHub |
|---|---|---|
| Version | 1.88.0 (open source, latest), chart 1.16.1 | v1.9.0, chart 1.1.12; prerequisites chart 0.3.1 |
| Licence | Apache 2.0; access control and SSO are in the paid edition | Apache 2.0; OIDC login is in the open-source chart (not tested) |
| Pods at idle | 2 (lakeFS, PostgreSQL) | 6 (GMS, frontend, actions, MySQL, OpenSearch, Kafka) |
| Requests | 0.2 CPU / 0.5 GiB | 1.6 CPU / 2.4 GiB (Kafka sets none) |
| Memory in use at idle | about 130 MiB | about 3.7 GiB |
| Storage | 5 Gi volume + a bucket on the lab's S3 store | 3 volumes of 8 Gi |
| CRDs | 0 | 0 |
| Install time | 26 s | 10 min 25 s, mostly image pulls |
| Hands-on effort | about 0.5 h including the adapter code | about 0.5 h including recipes |

Evidence: [lakefs/01-install.log](../evidence/lakefs/01-install.log), [lakefs/03-branch-rollback-footprint.log](../evidence/lakefs/03-branch-rollback-footprint.log), [datahub/01-install.log](../evidence/datahub/01-install.log), [datahub/02-footprint.txt](../evidence/datahub/02-footprint.txt).

Found later, while preparing the training (26 Nov): the lakeFS web console refuses to show its login page until a form with name, e-mail and country is filled in (it is sent to the vendor). Setting `email_subscription.enabled: false` removes it ([lakefs/values.yaml](../lakefs/values.yaml)). The POC had only used the API and the command line, so this went unnoticed.

## How W3 uses lakeFS

The change is in the shared test kit, not in the pipelines' shape: `testkit/dataset.py` hides the store, `testkit/lakefs.py` talks to lakeFS. A project switches by getting one Secret (`lakefs/project.sh`).

1. A new batch is written to the `main` branch and committed.
2. The detect step asks for the branch's commit id and checks whether a `trained-<model>-<version>` tag already points at it.
3. Validation and training read from that commit id, through lakeFS's S3 gateway.
4. After registration the commit is tagged, and the model version carries the commit id and a `lakefs://` URI.

## Results

| Check | Kubeflow | MLflow + Ray | Evidence |
|---|---|---|---|
| W3 first run on lakeFS data | Works, 276 s | Works, 211 s | [kubeflow-w3-run-1.log](../evidence/lakefs/kubeflow-w3-run-1.log), [mlflow-ray-w3.log](../evidence/lakefs/mlflow-ray-w3.log) |
| Run again, no new commit | Skips training, 65 s | Skips training, 31 s | [kubeflow-w3-ct-loop.log](../evidence/lakefs/kubeflow-w3-ct-loop.log), [mlflow-ray-w3.log](../evidence/lakefs/mlflow-ray-w3.log) |
| New commit → new model version (2-minute schedule) | 331 s | 249 s registered, 271 s served | same |
| Model version records the data commit | Yes, in Model Registry metadata | Yes, in MLflow tags | same |
| Read back the exact dataset of an older model | Yes: v4 → 2 batches, v5 → 3 batches | Yes: v4 → 2 batches, v5 → 3 batches | [kubeflow-reproduce.log](../evidence/lakefs/kubeflow-reproduce.log), [mlflow-ray-w3.log](../evidence/lakefs/mlflow-ray-w3.log) |
| Code changed in the pipeline | 3 components, same steps | 3 scripts, same steps | `kubeflow/workloads/w3_pipeline.py`, `mlflow-ray/workloads/w3_*.py` |

Candidate-independent checks on lakeFS:

| Check | Result | Evidence |
|---|---|---|
| Runs on the lab's S3 store (SeaweedFS) as backing storage | Works | [02-smoke-and-auth-model.log](../evidence/lakefs/02-smoke-and-auth-model.log) |
| Bad batch on a branch leaves `main` untouched; a merged bad batch can be reverted | Works | [03-branch-rollback-footprint.log](../evidence/lakefs/03-branch-rollback-footprint.log) |
| Second user, groups, policies | Fails: "Not Implemented" / "Already exists" | [02-smoke-and-auth-model.log](../evidence/lakefs/02-smoke-and-auth-model.log) |

The timings are slightly better than the original W3 runs (Kubeflow 331 s and 365 s, MLflow + Ray 282 s and 378 s). That is not lakeFS being faster: images were already on the nodes, and the wait for the 2-minute schedule varies. The fair reading is that lakeFS adds no measurable time.

DataHub:

| Check | Result | Evidence |
|---|---|---|
| Source for MLflow | Works: 2 model groups, 7 versions, runs and experiments in 22 s | [04-ingest-mlflow.log](../evidence/datahub/04-ingest-mlflow.log), [05-catalog-contents.log](../evidence/datahub/05-catalog-contents.log) |
| Source for lakeFS | None. Workaround: the generic S3 source pointed at the lakeFS gateway; datasets and schema appear, per branch path | [04-ingest-lakefs-s3.log](../evidence/datahub/04-ingest-lakefs-s3.log), [06-lineage-model-to-lakefs.log](../evidence/datahub/06-lineage-model-to-lakefs.log) |
| Source for Kubeflow (Pipelines, Model Registry) | None in the CLI's source list | [03-cli-plugins-login.log](../evidence/datahub/03-cli-plugins-login.log) |
| Lineage model version → run → dataset in lakeFS | Works for MLflow + Ray once the training run logs the dataset as an MLflow input (4 lines added). Versions trained before that show the run only | [06-lineage-model-to-lakefs.log](../evidence/datahub/06-lineage-model-to-lakefs.log) |
| Same lineage for Kubeflow | Not tested: needs our own emitter reading Model Registry | |
| OIDC login (for SRAM), scheduled ingestion, access policies | Not tested | |

## Issues and workarounds

| # | Tool | Issue | Severity | Workaround | Status |
|---|---|---|---|---|---|
| 1 | lakeFS | Open-source edition has a single user; no groups or policies. Every project would share one admin key, and anyone with it can read and change every repository | Major | One lakeFS instance per project (2 pods each), or the paid edition | open |
| 2 | lakeFS | The chart falls back to a fixed, published encryption key when no existing Secret is named | Minor | Set `existingSecret` | solved |
| 3 | lakeFS | The `installation` settings did not create the admin user on first start | Minor | Run `lakefs setup` once | solved |
| 4 | lakeFS | Still no data-event trigger in our pipelines: retraining polls on a schedule. lakeFS hooks could trigger on commit | Minor | Not tested | open |
| 5 | lakeFS | Our detect step reacts to any commit on the branch, not only to changes under the dataset path | Minor | Compare the path between commits | open |
| 6 | DataHub | Prerequisites chart 0.3.1 does not render with default values on Helm 4.1 (nil pointer in the OpenSearch subchart) | Minor | `--set opensearch.serviceMonitor.enabled=false` | solved |
| 7 | DataHub | Default login `datahub` / `datahub` works after install | Major until changed | Replace the default user, or switch to OIDC | open |
| 8 | DataHub | MySQL and Kafka come from the archived `bitnamilegacy` image repository | Minor | Bring our own MySQL and Kafka | open |
| 9 | DataHub | No Kubeflow source: Model Registry and pipeline runs are invisible to the catalog | Major for Kubeflow | Write an emitter with the DataHub SDK | open |
| 10 | DataHub | No lakeFS source: the catalog sees a branch as a folder; commits and tags are not shown. The commit id is only on the model version and the MLflow dataset | Minor | Naming convention between the MLflow input and the S3 dataset (`testkit/dataset.py`) | accepted |
| 11 | DataHub | The actions pod idles at 461 MiB of a 512 MiB limit | Minor | Raise the limit | open |

## What this means for the candidate pages

- **Stage 1 Data** stays as rated for the candidates themselves (Kubeflow Gap, MLflow + Ray Partial): neither versions data. With lakeFS added, both reach the same working result, so the stage stops being a difference between them.
- **Wrappers:** one more light wrapper on each side (the lakeFS adapter, shared code). For Kubeflow, a catalog would add a complex one (the DataHub emitter).
- **FAIR-readiness** stays Medium for both: lineage down to an immutable data commit now exists, but there are still no persistent identifiers, and the catalog was only exercised for MLflow + Ray.
- **Operational load:** lakeFS is negligible. DataHub adds a Kafka, a search cluster and a MySQL to run and back up.

## Not tested

- lakeFS: paid-edition access control and SSO, hooks, garbage collection, large files, backup and restore, upgrade.
- DataHub: OIDC with SRAM, scheduled ingestion, policies, a Kubeflow emitter, upgrade, backup and restore.
- Alternatives named earlier (DVC, object versioning with manifests, table formats) were not installed.

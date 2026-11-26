# MLOps lab training

Hands-on walk through the four things installed on the lab cluster: **Kubeflow**,
**MLflow + Ray**, **lakeFS** and **DataHub**. Every command here was run on this
lab on 26 Nov 2026. You type the commands on the desktop that hosts the VMs.

| Part | What you do | Time |
|---|---|---|
| [0. Start the lab](#0-start-the-lab) | Open the UIs, find the logins | 5 min |
| [1. Kubeflow](01-kubeflow.md) | Notebook, tracking, pipeline, tuning, 2-node training, registry, endpoint | 60–75 min |
| [2. MLflow + Ray](02-mlflow-ray.md) | Tracking UI, notebook, Ray job, pipeline, registry, endpoint | 50–60 min |
| [3. lakeFS](03-lakefs.md) | Commits, branches, revert, then new data → new model on both stacks | 40 min |
| [4. DataHub](04-datahub.md) | Search, ingestion, lineage from model to dataset, ownership | 30 min |

Parts 1 and 2 are independent. Part 3 needs nothing from 1 or 2, but makes more
sense after one of them. Part 4 shows what part 3 produced, so do it last.

The map of which tool covers which step is in
[findings/solutions-map.excalidraw](../findings/solutions-map.excalidraw); the
test results are in [findings/comparison.md](../findings/comparison.md).

## 0. Start the lab

Open a terminal in the repository (`/data/instant-rke2-lab`).

**1. Check the VMs are up.** They keep running unless the desktop was rebooted.

```bash
virsh -c qemu:///system list --all
```

If cp1, worker1 or worker2 is "shut off", start it (`virsh -c qemu:///system start cp1`,
same for the others) and wait about five minutes for the pods to settle.

**2. Load the lab environment.** Do this in every new terminal.

```bash
source mlops/training/env.sh
```

It sets `KUBECONFIG` for this terminal only (your default kubeconfig is not
touched) and adds these helpers:

| Helper | What it runs |
|---|---|
| `$KF`, `$MR` | The two training projects: `kubeflow-user-example-com` and `mr-alpha` |
| `kf-kit`, `mr-kit` | Python in each project's workstation pod, with the project's credentials |
| `lakectl` | The lakeFS command line, inside the lakeFS pod |
| `datahub`, `datahub-ingest` | The DataHub command line, inside the ingestion pod |

**3. Open the UIs.**

```bash
mlops/training/lab.sh up
```

```bash
mlops/training/lab.sh logins
```

| UI | URL | Login |
|---|---|---|
| Kubeflow | http://localhost:8080 | `user@example.com` / `12341234` |
| MLflow | http://localhost:5001 | `mr-alpha` and its password from `lab.sh logins` |
| JupyterHub | http://localhost:8081 | You sign up yourself in part 2 |
| lakeFS | http://localhost:8000 | Access key and secret key from `lab.sh logins` |
| DataHub | http://localhost:9002 | `datahub` / `datahub` (paused until part 4) |
| Ray dashboard | http://localhost:8265 | None |

The URLs only work on the desktop itself, and only while `lab.sh up` is active.
`lab.sh status` shows what answers; `lab.sh down` stops the forwards.

**4. Check health.**

```bash
mlops/training/lab.sh status
```

Expect three nodes `Ready`, `pods not Running/Completed: 0`, five `ok` lines and
`datahub paused`.

## Good to know before you start

- **The cluster is nearly full.** Both stacks and lakeFS run at once on two
  worker VMs (12 vCPU, 32 GiB). Run one training job or pipeline at a time, and
  wait for it to finish before starting the next. A pod that stays `Pending`
  means exactly this.
- **DataHub is paused**, to leave room for parts 1–3. Part 4 starts it
  (`lab.sh resume-datahub`, about 5 minutes) and you pause it again afterwards
  (`lab.sh pause-datahub`). Its data is kept while paused.
- **Everything is slow the first time.** There is no image registry, so jobs
  install their Python packages at start, and the worker disks are on a USB hard
  drive. The times given are what I measured.
- **LLM endpoints sleep.** They scale to zero after a few minutes; the next
  request takes 25–130 s.
- **The control-plane VM is small** (4 vCPU, 8 GiB) and it is not protected:
  Kubernetes will place pods on it. While preparing this training a Ray worker
  landed there and ran it out of memory, which stalled the whole cluster for a
  few minutes. The two training-job manifests now keep their pods on the
  workers. If you write your own job, copy their `nodeAffinity` block.
- **If the cluster stalls** (`kubectl` times out): wait two or three minutes,
  delete the job you started last, then `lab.sh status`. If the Kubeflow
  Pipelines page stays broken: `kubectl -n kubeflow delete pod -l app=ml-pipeline-ui`.

## Clean up

```bash
mlops/training/lab.sh reset
```

Removes the Katib experiment, the training jobs and the lakeFS repository the
exercises create. Notebook servers, MLflow runs and model versions stay: delete
them in their UIs if you want a clean slate.

## Files

| File | What |
|---|---|
| `env.sh` | Shell helpers; source it |
| `lab.sh` | `up`, `status`, `logins`, `down`, `reset`, `pause-datahub`, `resume-datahub` |
| `add_batch.py`, `dataset_of_model.py` | Part 3: commit a new data batch; read back the data behind each model |
| `datahub/lineage.py` | Part 4: upstream lineage of a model version |
| `kubeflow/poddefaults.yaml` | Already applied: lets notebooks reach Pipelines and MLflow |
| `kubeflow/notebook_tracking.py`, `notebook_pipeline.py` | The notebook cells of part 1 |
| `kubeflow/trainjob.yaml`, `mlflow-ray/rayjob.yaml` | 2-node fine-tuning job for each stack |
| `kubeflow/registry.py`, `predict.py`, `mlflow-ray/registry.py`, `predict.py` | Small scripts you run through `kf-kit` / `mr-kit` |

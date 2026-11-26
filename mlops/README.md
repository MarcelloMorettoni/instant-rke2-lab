# MLOps platform POC: Kubeflow vs MLflow + Ray

A hands-on comparison of two MLOps candidates on the lab cluster from `make all`
(3 VMs, RKE2 + Cilium, CPU only). Same five reference workloads, same code and
data for both.

**Start with the results:** [findings/comparison.md](findings/comparison.md), then
[findings/kubeflow.md](findings/kubeflow.md) and [findings/mlflow-ray.md](findings/mlflow-ray.md).

## Layout

| Path | What |
|---|---|
| `findings/` | One findings page per candidate (POC template) and the side-by-side comparison |
| `evidence/` | Command output behind every result |
| `testkit/` | Shared workload code: tabular model (W3), language-model fine-tune (W2), object-store helpers, LLM load client (W4) |
| `kubeflow/` | Install scripts and workloads for Kubeflow |
| `mlflow-ray/` | Install scripts, tenancy script and workloads for MLflow + Ray |
| `lakefs/` | Add-on test: lakeFS install and the per-project script that switches W3 to versioned data |
| `datahub/` | Add-on test: DataHub install, ingestion pod and recipes |
| `lib.sh` | Pinned versions and shared helpers |

## Reproduce

Needs the lab cluster up, `helm`, `jq`, `uv` and about 40 GB free where the VM disks live.

```bash
mlops/kubeflow/install.sh                 # Kubeflow v1.11.0 (about 15 min)
mlops/kubeflow/install-model-registry.sh
mlops/mlflow-ray/install-mlflow.sh        # MLflow + PostgreSQL + S3
mlops/mlflow-ray/install-kuberay.sh
mlops/mlflow-ray/install-argo.sh
mlops/mlflow-ray/install-jupyterhub.sh
mlops/mlflow-ray/tenant.sh mr-alpha 8 16Gi
```

The workloads were driven by hand from `kubeflow/workloads/` and
`mlflow-ray/workloads/`; the findings pages name the file for each one.
Generated credentials are in `.state/mlops-*.env` (gitignored).

## Things to know

- Kubeflow puts about 15 GB of images on every worker. Keep the control-plane
  VM's disk on fast storage and Ray heads off the 8 GiB control-plane node.
- Both stacks share the cluster. Kubeflow's Argo controller is cluster-wide, so
  the MLflow + Ray Argo controller uses an instance ID and the 3.7 release line.
- Not covered: GPUs, vLLM, SRAM, Slurm.

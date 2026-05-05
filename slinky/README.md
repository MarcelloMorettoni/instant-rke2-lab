# Slinky on the lab

Run [Slinky](https://slinky.schedmd.com/) (SchedMD's SLURM-on-Kubernetes) on
top of the `instant-rke2-lab` cluster, then exercise scheduling and small MPI
jobs with just two worker nodes.

## What gets installed

| Component | Helm chart | Namespace | What for |
|-----------|------------|-----------|----------|
| local-path-provisioner | apply YAML | `local-path-storage` | default StorageClass (RKE2 ships none) |
| cert-manager | `jetstack/cert-manager` | `cert-manager` | webhook certs for the operator |
| slurm-operator-crds | `oci://ghcr.io/slinkyproject/charts/slurm-operator-crds` | (cluster-scoped) | `NodeSet` / `LoginSet` / `Token` CRDs |
| slurm-operator | `oci://ghcr.io/slinkyproject/charts/slurm-operator` | `slinky` | reconciles SLURM resources |
| slurm | `oci://ghcr.io/slinkyproject/charts/slurm` | `slurm` | the actual SLURM cluster (slurmctld + 2× slurmd + login) |

Sized for the lab's two workers:

- 1 `controller` (slurmctld) — pinned by the operator
- 2 `slurmd` pods (one per worker, anti-affinity)
- 1 `login` pod (your sbatch entrypoint)
- 2 partitions:
  - `general` — `PriorityTier=1`, default
  - `priority` — `PriorityTier=10`, for preemption-style demos

## Install

From the lab root, after `make all` finishes and `kubectl get nodes` shows
3 Ready nodes:

```bash
cd slinky
./install.sh
```

That pulls helm if missing, deploys local-path / cert-manager / the operator
stack, then the SLURM cluster with values from
[`values/slurm.yaml`](./values/slurm.yaml). Re-run any time — it's idempotent.

When done:

```bash
./scripts/status.sh        # sinfo + squeue
./scripts/login.sh         # interactive shell in the login pod
./scripts/submit.sh examples/01-hello.sbatch
```

## What to play with

### Scheduling

| File | Demonstrates |
|------|--------------|
| `01-hello.sbatch` | smallest-possible sbatch, single task |
| `02-array.sbatch` | 10-task job array — backfill scheduler distributes across both workers |
| `03-priority-low.sbatch` | long job on `general` (low tier) occupying both nodes |
| `03-priority-high.sbatch` | short job on `priority` — submit while the low job is running and watch the priority partition jump ahead |
| `04-multinode-srun.sbatch` | one task per worker via plain `srun` (no MPI library needed) |

Recipe for the priority demo:

```bash
./scripts/submit.sh examples/03-priority-low.sbatch    # fills both workers
./scripts/submit.sh examples/03-priority-high.sbatch   # queues; jumps ahead by tier
./scripts/status.sh                                    # watch the queue
```

### MPI

The slurmd image is Ubuntu-based, so OpenMPI installs cleanly inside it on
first run. If you re-create the cluster, the install repeats once.

| File | Demonstrates |
|------|--------------|
| `05-mpi-hello.sbatch` | 4 ranks across 2 nodes, MPI hello-world via PMIx |
| `06-mpi-pingpong.sbatch` | inter-node ping-pong, prints one-way latency per message size |

Note: ping-pong latency in this lab will look bad (single-digit-ms range) —
traffic crosses `virbr0` plus Cilium's eBPF datapath plus the kernel TCP
stack. Useful for *correctness*, not for benchmarking.

## Layout

```
slinky/
├── install.sh                # the full install, idempotent
├── uninstall.sh              # helm-uninstall the slurm bits; --all also removes cert-manager + local-path
├── values/
│   ├── slurm.yaml            # 2 workers, 2 partitions, login pod ClusterIP
│   └── slurm-operator.yaml   # operator overrides (default-ish)
├── scripts/
│   ├── lib.sh                # locates the login pod
│   ├── login.sh              # kubectl exec -it into the login pod
│   ├── submit.sh <file>      # cp + sbatch a script
│   ├── status.sh             # sinfo + squeue + pod overview
│   └── logs.sh <jobid>       # scontrol show job + locate output files
└── examples/                 # sbatch scripts (above)
```

## Troubleshooting

**Pods stuck `Pending` with `unbound PVC`.** No default StorageClass yet.
`kubectl get sc` should show `local-path` marked default — re-run `install.sh`.

**`slurmctld` keeps CrashLooping.** The most common cause is the controller
PVC being stuck. `kubectl -n slurm describe pvc` and check the local-path-
provisioner logs in `local-path-storage`.

**`mpicc not found` and apt-install fails.** The slurmd image is run as
non-root in some chart versions. Either flip the chart's compute pod
`securityContext.runAsUser` to `0`, or pre-bake an MPI image and override
`nodesets.slinky.slurmd.image`.

**`make all` from the lab root + `./install.sh` from here = full reset.**

## References

- [Slinky overview (SchedMD)](https://www.schedmd.com/introducing-slinky-slurm-kubernetes/)
- [slurm-operator docs](https://slinky.schedmd.com/projects/slurm-operator/)
- [slurm-operator GitHub](https://github.com/SlinkyProject/slurm-operator)

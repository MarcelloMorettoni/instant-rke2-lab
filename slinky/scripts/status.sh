#!/usr/bin/env bash
# Quick status: nodes, partitions, queue.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

POD="$(login_pod)"
echo "── sinfo ──"
kubectl -n "$SLURM_NS" exec "$POD" -- sinfo -lN || true
echo
echo "── squeue ──"
kubectl -n "$SLURM_NS" exec "$POD" -- squeue -o '%.10i %.9P %.20j %.8u %.2t %.10M %.6D %R' || true
echo
echo "── slurmctld pod ──"
kubectl -n "$SLURM_NS" get pods -l app.kubernetes.io/component=controller -o wide || true
echo
echo "── nodesets ──"
kubectl -n "$SLURM_NS" get pods -l app.kubernetes.io/component=compute -o wide \
  || kubectl -n "$SLURM_NS" get pods -l app.kubernetes.io/name=slurmd -o wide \
  || kubectl -n "$SLURM_NS" get pods

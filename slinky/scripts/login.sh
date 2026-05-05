#!/usr/bin/env bash
# Drop into the slurm login pod for interactive sbatch / squeue / sinfo.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

POD="$(login_pod)"
echo "Exec into ${SLURM_NS}/${POD}"
kubectl -n "$SLURM_NS" exec -it "$POD" -- bash -l

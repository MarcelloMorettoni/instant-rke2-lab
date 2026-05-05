#!/usr/bin/env bash
# Submit an sbatch script via the login pod.
# Usage: submit.sh examples/01-hello.sbatch [extra sbatch args]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

[[ $# -ge 1 ]] || { echo "usage: $0 <sbatch-file> [sbatch args...]"; exit 2; }
FILE="$1"; shift
[[ -f "$FILE" ]] || { echo "no such file: $FILE"; exit 1; }

POD="$(login_pod)"
NAME="$(basename "$FILE")"
REMOTE="/tmp/${NAME}"

kubectl -n "$SLURM_NS" cp "$FILE" "${POD}:${REMOTE}"
kubectl -n "$SLURM_NS" exec "$POD" -- bash -lc "chmod +x ${REMOTE} && sbatch ${*} ${REMOTE}"

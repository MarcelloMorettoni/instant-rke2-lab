#!/usr/bin/env bash
# Tail logs of a slurm job by ID. Reads /home/<user>/<job>-<id>.out from the login pod.
# Usage: logs.sh <jobid>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

JID="${1:-}"
[[ -n "$JID" ]] || { echo "usage: $0 <jobid>"; exit 2; }

POD="$(login_pod)"
kubectl -n "$SLURM_NS" exec "$POD" -- bash -lc \
  "ls -1 /tmp /root /home/*/ 2>/dev/null | grep -E '\\-${JID}\\.out|\\-${JID}\\.err|slurm-${JID}' | head -20"
echo "── try: scontrol show job ${JID} ──"
kubectl -n "$SLURM_NS" exec "$POD" -- scontrol show job "${JID}" 2>/dev/null || true

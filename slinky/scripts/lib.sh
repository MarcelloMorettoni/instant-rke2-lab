#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
__LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${__LIB_DIR}/../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${LAB_ROOT}/.state/kubeconfig}"

SLURM_NS="${SLURM_NS:-slurm}"

login_pod() {
  local pod
  pod="$(kubectl -n "$SLURM_NS" get pods \
        -l app.kubernetes.io/component=login \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    pod="$(kubectl -n "$SLURM_NS" get pods -o name 2>/dev/null \
          | grep -i login | head -1 | sed 's|pod/||')"
  fi
  [[ -n "$pod" ]] || { echo "no login pod found in namespace ${SLURM_NS}" >&2; return 1; }
  echo "$pod"
}

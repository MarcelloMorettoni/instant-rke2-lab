#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

for entry in "${VM_LIST[@]}"; do
  read -r name vcpus mem disk ip role <<<"$entry"
  if VIRSH dominfo "$name" >/dev/null 2>&1; then
    log "Destroying VM ${name}"
    VIRSH destroy "$name" 2>/dev/null || true
    VIRSH undefine "$name" --remove-all-storage --nvram 2>/dev/null \
      || VIRSH undefine "$name" --remove-all-storage 2>/dev/null \
      || VIRSH undefine "$name" 2>/dev/null \
      || true
  fi
  rm -rf "${VM_DIR:?}/${name}" 2>/dev/null \
    || sudo rm -rf "${VM_DIR:?}/${name}" 2>/dev/null \
    || true
done

rm -f "${STATE_DIR}/node-token" "${STATE_DIR}/kubeconfig"
ok "Lab destroyed"
VIRSH list --all || true

#!/usr/bin/env bash
# Full lab teardown: everything `make destroy` removes, plus everything else
# the lab created on the host, so the next `make all` starts from nothing.
#
#   - VMs, disks, kubeconfig, node-token     (99-destroy.sh)
#   - the libvirt storage pool  ${POOL_NAME}
#   - images/  (cloud image, re-downloaded by `make image`)
#   - vms/
#   - .state/  (SSH keypair, soft-tenancy credentials, ...)
#
# Kept: host packages, kubectl/helm, kvm/libvirt group membership, the libvirt
# default network and the search ACLs on parent directories — all host setup
# that `make prereqs` would just redo. See README "Tear down completely".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

warn "make clean removes the VMs, the storage pool '${POOL_NAME}', and"
warn "  ${IMAGE_DIR}  ${VM_DIR}  ${STATE_DIR}  (including the lab SSH key)"
if [[ "${YES:-}" != "1" ]]; then
  read -r -p "Type 'yes' to continue: " answer
  [[ "${answer}" == "yes" ]] || die "Aborted"
fi

"${SCRIPT_DIR}/99-destroy.sh"

if VIRSH pool-info "${POOL_NAME}" >/dev/null 2>&1; then
  log "Removing libvirt storage pool ${POOL_NAME}"
  VIRSH pool-destroy "${POOL_NAME}" >/dev/null 2>&1 || true
  VIRSH pool-undefine "${POOL_NAME}" >/dev/null
fi

for d in "${IMAGE_DIR}" "${VM_DIR}" "${STATE_DIR}"; do
  [[ -e "$d" ]] || continue
  log "Removing ${d}"
  # libvirt may have chowned files to libvirt-qemu; fall back to sudo.
  rm -rf "${d:?}" 2>/dev/null || sudo rm -rf "${d:?}"
done

ok "Lab cleaned. 'make all' rebuilds it from scratch."

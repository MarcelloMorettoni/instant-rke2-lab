#!/usr/bin/env bash
# Interactive SSH to a lab VM by name (default: the control plane).
#   scripts/ssh-node.sh            # cp1 (multi) or solo (solo)
#   scripts/ssh-node.sh worker1
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME="${1:-$(control_plane_name)}"
IP="$(vm_ip "${NAME}")" || {
  names=(); for e in "${VM_LIST[@]}"; do read -r n _ <<<"$e"; names+=("$n"); done
  die "No VM '${NAME}' in the ${TOPOLOGY} lab (VMs: ${names[*]})"
}
exec ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR "${SSH_USER}@${IP}"

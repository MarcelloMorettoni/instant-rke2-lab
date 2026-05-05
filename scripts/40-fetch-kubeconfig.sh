#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CP_IP="$(control_plane_ip)"
[[ -n "$CP_IP" ]] || die "No 'server' role in VM_LIST"

KCONF="${STATE_DIR}/kubeconfig"
log "Fetching kubeconfig from ${CP_IP}"
ssh_run "${CP_IP}" "sudo cat /etc/rancher/rke2/rke2.yaml" > "${KCONF}.tmp"

# Rewrite server URL so the host can reach the API server through virbr0
sed -i \
  -e "s|server: https://127\.0\.0\.1:6443|server: https://${CP_IP}:6443|g" \
  -e "s|server: https://localhost:6443|server: https://${CP_IP}:6443|g" \
  "${KCONF}.tmp"
mv "${KCONF}.tmp" "${KCONF}"
chmod 600 "${KCONF}"

ok "Kubeconfig saved to: ${KCONF}"
echo
echo "── To use it (one-shot):"
echo "    export KUBECONFIG=${KCONF}"
echo "    kubectl get nodes"
echo
echo "── To merge into your default config:"
echo "    KUBECONFIG=${KCONF}:\$HOME/.kube/config kubectl config view --flatten > \$HOME/.kube/config.merged"
echo "    mv \$HOME/.kube/config.merged \$HOME/.kube/config"
echo

if [[ "${1:-}" == "--print" ]]; then
  echo "── Kubeconfig contents ──"
  cat "${KCONF}"
fi

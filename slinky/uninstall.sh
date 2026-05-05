#!/usr/bin/env bash
# Remove everything install.sh added. cert-manager and local-path-provisioner
# are kept by default (other things may depend on them) — pass --all to nuke.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${LAB_ROOT}/.state/kubeconfig}"

helm uninstall -n slurm  slurm                 2>/dev/null || true
helm uninstall -n slinky slurm-operator        2>/dev/null || true
helm uninstall          slurm-operator-crds    2>/dev/null || true
kubectl delete ns slurm  --ignore-not-found
kubectl delete ns slinky --ignore-not-found

if [[ "${1:-}" == "--all" ]]; then
  helm uninstall -n cert-manager cert-manager 2>/dev/null || true
  kubectl delete ns cert-manager --ignore-not-found
  kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml --ignore-not-found
fi

echo "Slinky uninstalled."

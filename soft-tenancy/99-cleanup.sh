#!/usr/bin/env bash
# Remove everything the soft-tenancy exercises created.
#   ./99-cleanup.sh          workloads, policies, namespaces, Helm releases
#   ./99-cleanup.sh --all    ...and the generated credentials in .state/
#
# Step 00's Cilium setting (NXDOMAIN for blocked names) is left in place: it's
# harmless without DNS policies. To revert it, re-upload the original
# manifests/rke2-cilium-config.yaml (or rebuild the lab with `make all`).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
require_cluster

log "Helm releases"
for r in grafana alloy loki; do
  helm -n "${OBS_NS}" uninstall "$r" --wait 2>/dev/null || true
done

log "Policies, guardrails, admission guard"
kubectl delete -f "${HERE}/10-observability-lockdown/policies.yaml" --ignore-not-found
kubectl delete -f "${HERE}/03-tenant-isolation/" --ignore-not-found
kubectl delete -f "${HERE}/02-tenant-guardrails/" --ignore-not-found
kubectl delete -f "${HERE}/01-namespaces/namespace-guard.yaml" --ignore-not-found

log "Namespaces (takes a moment: PVCs and pods drain first)"
kubectl delete -f "${HERE}/01-namespaces/namespaces.yaml" --ignore-not-found --wait=true
kubectl delete clusterrole alloy-pod-discovery --ignore-not-found
kubectl delete clusterrolebinding alloy-pod-discovery --ignore-not-found

if [[ "${1:-}" == "--all" ]]; then
  rm -rf "${CREDS_DIR}"
  ok "Removed ${CREDS_DIR}"
fi
ok "Soft-tenancy exercises cleaned up"

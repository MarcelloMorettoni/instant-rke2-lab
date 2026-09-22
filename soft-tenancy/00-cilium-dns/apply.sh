#!/usr/bin/env bash
# Step 00: make Cilium's DNS proxy answer NXDOMAIN for names a policy blocks.
#
# The Cilium chart is managed by RKE2 from a HelmChartConfig file on cp1. We
# re-render the lab's template with our extra values and upload it to the same
# place, so the change survives rke2-server restarts (a `kubectl edit` would
# be reverted by RKE2).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib.sh
source "${HERE}/../../scripts/lib.sh"     # ssh_run, control_plane_ip, config.env
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster

# Already done (for example on a re-run of make soft-tenancy): nothing to do,
# and no need to restart every Cilium agent again.
if [[ "$(kubectl -n kube-system get cm cilium-config \
         -o jsonpath='{.data.tofqdns-dns-reject-response-code}' 2>/dev/null)" == "nameError" ]]; then
  ok "Step 00: Cilium already answers blocked names with NXDOMAIN"
  exit 0
fi
command -v envsubst >/dev/null || die "envsubst not found (apt install gettext-base)"

CP_IP="$(control_plane_ip)"
TPL="${LAB_ROOT}/manifests/rke2-cilium-config.yaml"
FRAGMENT="${HERE}/cilium-dns-values.yaml"
REMOTE="/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml"

log "Rendering ${TPL##*/} + ${FRAGMENT##*/}"
# valuesContent is the last key in the template, so appending the fragment
# indented by 4 spaces extends the Helm values. Comment/blank lines are dropped.
# shellcheck disable=SC2016  # envsubst wants the literal variable names
RENDERED="$(
  CP_IP="${CP_IP}" CILIUM_HUBBLE_UI="${CILIUM_HUBBLE_UI}" \
    envsubst '${CP_IP} ${CILIUM_HUBBLE_UI}' < "${TPL}"
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e 's/^/    /' "${FRAGMENT}"
)"

log "Uploading HelmChartConfig to ${CP_IP}:${REMOTE}"
ssh_run "${CP_IP}" "sudo tee ${REMOTE} >/dev/null" <<<"${RENDERED}"

log "Waiting for RKE2's helm-controller to roll the value into cilium-config"
for _ in $(seq 1 60); do
  CODE="$(kubectl -n kube-system get cm cilium-config \
          -o jsonpath='{.data.tofqdns-dns-reject-response-code}' 2>/dev/null || true)"
  [[ "${CODE}" == "nameError" ]] && break
  sleep 5
done
[[ "${CODE:-}" == "nameError" ]] \
  || die "cilium-config still says '${CODE:-<unset>}'. Check: kubectl -n kube-system get helmchart rke2-cilium -o yaml"
ok "cilium-config: tofqdns-dns-reject-response-code=nameError"

# The chart sets rollOutCiliumPods=false, so agents don't restart by themselves.
log "Restarting Cilium agents to pick it up"
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=5m
ok "Step 00 done"

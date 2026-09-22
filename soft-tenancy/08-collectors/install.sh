#!/usr/bin/env bash
# Step 08: the collectors.
#   Alloy DaemonSet       pulls logs, metrics and profiles, one pipeline per tenant
#   otlp-tenant-a / -b    per-tenant OTLP receivers for traces
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
require_helm

log "Alloy ${ALLOY_CHART_VERSION} DaemonSet (logs, metrics, profiles)"
helm upgrade --install alloy grafana/alloy --version "${ALLOY_CHART_VERSION}" \
  --namespace "${OBS_NS}" -f "${HERE}/alloy-values.yaml" --wait --timeout 5m

log "Per-tenant OTLP receivers (traces)"
kubectl apply -f "${HERE}/otlp-receivers.yaml"
kubectl -n "${OBS_NS}" rollout restart deploy/otlp-tenant-a deploy/otlp-tenant-b >/dev/null  # pick up config edits
for t in a b; do kubectl -n "${OBS_NS}" rollout status "deploy/otlp-tenant-${t}" --timeout=3m; done
ok "Step 08 done: Alloy on every node; otlp-tenant-a / otlp-tenant-b.${OBS_NS}.svc:4317"

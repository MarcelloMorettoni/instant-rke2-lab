#!/usr/bin/env bash
# Step 08: Alloy DaemonSet, the only writer to Loki.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
require_helm

log "Installing Alloy ${ALLOY_CHART_VERSION} into ${OBS_NS}"
helm upgrade --install alloy grafana/alloy \
  --version "${ALLOY_CHART_VERSION}" \
  --namespace "${OBS_NS}" \
  -f "${HERE}/values.yaml" \
  --wait --timeout 5m
ok "Step 08 done: one Alloy per node, shipping to loki.${OBS_NS}.svc:3100"

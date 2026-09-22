#!/usr/bin/env bash
# Step 06: Loki, single binary, auth_enabled (multi-tenant).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
require_helm
ensure_default_storageclass

log "Installing Loki ${LOKI_CHART_VERSION} into ${OBS_NS}"
helm upgrade --install loki grafana/loki \
  --version "${LOKI_CHART_VERSION}" \
  --namespace "${OBS_NS}" \
  -f "${HERE}/values.yaml" \
  --wait --timeout 10m
ok "Step 06 done: loki.${OBS_NS}.svc:3100"

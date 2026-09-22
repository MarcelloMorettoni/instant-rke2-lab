#!/usr/bin/env bash
# Step 09: Grafana, then orgs/users/data sources via setup-orgs.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
require_helm
ensure_default_storageclass

log "Installing Grafana ${GRAFANA_CHART_VERSION} into ${OBS_NS}"
helm upgrade --install grafana grafana-community/grafana \
  --version "${GRAFANA_CHART_VERSION}" \
  --namespace "${OBS_NS}" \
  -f "${HERE}/values.yaml" \
  --wait --timeout 5m

"${HERE}/setup-orgs.sh"

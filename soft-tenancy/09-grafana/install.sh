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
  --set-string adminPassword="${ST_PASSWORD}" \
  --wait --timeout 5m

# Grafana applies adminPassword only when it creates its database. Set it
# explicitly, so an existing install (with an older password) matches too.
kubectl -n "${OBS_NS}" exec deploy/grafana -c grafana -- \
  grafana cli admin reset-admin-password "${ST_PASSWORD}" >/dev/null

"${HERE}/setup-orgs.sh"

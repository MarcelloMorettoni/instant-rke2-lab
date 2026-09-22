#!/usr/bin/env bash
# Step 06: the observability backends. All single binary, all multi-tenant.
#   Loki (logs) · Mimir (metrics) · Tempo (traces) · Pyroscope (profiles)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
require_helm
ensure_default_storageclass

log "Loki ${LOKI_CHART_VERSION} (logs)"
helm upgrade --install loki grafana/loki --version "${LOKI_CHART_VERSION}" \
  --namespace "${OBS_NS}" -f "${HERE}/loki-values.yaml" --wait --timeout 10m

log "Mimir ${MIMIR_VERSION} (metrics)"
kubectl apply -f "${HERE}/mimir.yaml"
kubectl -n "${OBS_NS}" rollout status statefulset/mimir --timeout=5m

log "Tempo, chart ${TEMPO_CHART_VERSION} (traces)"
helm upgrade --install tempo grafana-community/tempo --version "${TEMPO_CHART_VERSION}" \
  --namespace "${OBS_NS}" -f "${HERE}/tempo-values.yaml" --wait --timeout 10m

log "Pyroscope ${PYROSCOPE_CHART_VERSION} (profiles)"
helm upgrade --install pyroscope grafana/pyroscope --version "${PYROSCOPE_CHART_VERSION}" \
  --namespace "${OBS_NS}" -f "${HERE}/pyroscope-values.yaml" --wait --timeout 10m

ok "Step 06 done:"
echo "    loki.${OBS_NS}.svc:3100   mimir.${OBS_NS}.svc:8080   tempo.${OBS_NS}.svc:3200 (OTLP :4317)   pyroscope.${OBS_NS}.svc:4040"

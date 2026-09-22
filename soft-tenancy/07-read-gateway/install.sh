#!/usr/bin/env bash
# Step 07: the read gateway (kgateway) in front of Loki, Mimir, Tempo, Pyroscope.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
ensure_credentials
install_kgateway

# One API key per view (Grafana org). Each Secret holds exactly one key, and
# only that view's TrafficPolicy references it (views.yaml).
log "Creating one gateway key per view: tenant-a, tenant-b, tenant-c, platform"
for view in tenant-a tenant-b tenant-c platform; do
  var="OBS_KEY_$(tr 'a-z-' 'A-Z_' <<<"${view}")"
  kubectl -n "${OBS_NS}" create secret generic "obs-key-${view}" \
    --from-literal="${view}=${!var}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# Earlier versions of this lab: an nginx gateway, then one kgateway listener
# per backend with a single key Secret. Remove what's left of them, but never
# the objects kgateway manages (it creates a Deployment, a Service and a
# ConfigMap called obs-gateway too).
for obj in deploy/obs-gateway svc/obs-gateway configmap/obs-gateway; do
  owner="$(kubectl -n "${OBS_NS}" get "${obj}" --ignore-not-found \
           -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  if kubectl -n "${OBS_NS}" get "${obj}" >/dev/null 2>&1 && [[ "${owner}" != kgateway ]]; then
    log "Removing ${obj} of the old nginx gateway"
    kubectl -n "${OBS_NS}" delete "${obj}"
  fi
done
kubectl -n "${OBS_NS}" delete secret obs-gateway-htpasswd obs-gateway-keys --ignore-not-found >/dev/null
kubectl -n "${OBS_NS}" delete httproute obs-loki obs-mimir obs-tempo obs-pyroscope --ignore-not-found >/dev/null
kubectl -n "${OBS_NS}" delete trafficpolicy obs-gateway-tenant --ignore-not-found >/dev/null

log "Applying the Gateway and one view per Grafana org"
kubectl apply -f "${HERE}/gateway.yaml" -f "${HERE}/views.yaml"
kubectl -n "${OBS_NS}" wait --for=condition=Programmed gateway/obs-gateway --timeout=180s
kubectl -n "${OBS_NS}" rollout status deploy/obs-gateway --timeout=3m
ok "Step 07 done: obs-gateway.${OBS_NS}.svc:8080, views /tenant-a/ /tenant-b/ /tenant-c/ /platform/"

#!/usr/bin/env bash
# Step 07: the read gateway (kgateway) in front of Loki, Mimir, Tempo, Pyroscope.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
ensure_credentials
install_kgateway

# One API key per tenant. The entry's name IS the tenant ID on every backend.
log "Creating the gateway keys for tenant-a, tenant-b, platform"
kubectl -n "${OBS_NS}" create secret generic obs-gateway-keys \
  --from-literal=tenant-a="${OBS_KEY_TENANT_A}" \
  --from-literal=tenant-b="${OBS_KEY_TENANT_B}" \
  --from-literal=platform="${OBS_KEY_PLATFORM}" \
  --dry-run=client -o yaml | kubectl apply -f -

# The nginx gateway of earlier versions of this lab used the same names. Remove
# those objects, but never the ones kgateway manages (it creates a Deployment,
# a Service and a ConfigMap called obs-gateway too).
for obj in deploy/obs-gateway svc/obs-gateway configmap/obs-gateway; do
  owner="$(kubectl -n "${OBS_NS}" get "${obj}" --ignore-not-found \
           -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  if kubectl -n "${OBS_NS}" get "${obj}" >/dev/null 2>&1 && [[ "${owner}" != kgateway ]]; then
    log "Removing ${obj} of the old nginx gateway"
    kubectl -n "${OBS_NS}" delete "${obj}"
  fi
done
kubectl -n "${OBS_NS}" delete secret obs-gateway-htpasswd --ignore-not-found >/dev/null

log "Applying the Gateway, its policies and one route per backend"
kubectl apply -f "${HERE}/gateway.yaml"
kubectl -n "${OBS_NS}" wait --for=condition=Programmed gateway/obs-gateway --timeout=180s
kubectl -n "${OBS_NS}" rollout status deploy/obs-gateway --timeout=3m
ok "Step 07 done: obs-gateway.${OBS_NS}.svc  :3100 Loki  :8080 Mimir  :3200 Tempo  :4040 Pyroscope"

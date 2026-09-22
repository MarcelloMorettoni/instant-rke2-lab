#!/usr/bin/env bash
# Step 07: deploy the authenticating read gateway in front of Loki.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
ensure_credentials

# One htpasswd line per Loki tenant. The username IS the Loki tenant ID.
log "Building htpasswd for tenant-a, tenant-b, platform"
HTPASSWD="$(
  printf 'tenant-a:%s\n' "$(openssl passwd -apr1 "${LOKI_PW_TENANT_A}")"
  printf 'tenant-b:%s\n' "$(openssl passwd -apr1 "${LOKI_PW_TENANT_B}")"
  printf 'platform:%s\n' "$(openssl passwd -apr1 "${LOKI_PW_PLATFORM}")"
)"
kubectl -n "${OBS_NS}" create secret generic loki-gateway-htpasswd \
  --from-literal=htpasswd="${HTPASSWD}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Applying gateway"
# Stamp a hash of the manifest into the pod template, so editing nginx.conf
# rolls the pod (a subPath-mounted ConfigMap never updates in place).
REV="$(sha256sum "${HERE}/gateway.yaml" | cut -c1-12)"
sed "s|soft-tenancy/config-rev: \"0\"|soft-tenancy/config-rev: \"${REV}\"|" "${HERE}/gateway.yaml" \
  | kubectl apply -f -
kubectl -n "${OBS_NS}" rollout status deploy/loki-gateway --timeout=3m
ok "Step 07 done: loki-gateway.${OBS_NS}.svc:8080 (users: tenant-a, tenant-b, platform)"

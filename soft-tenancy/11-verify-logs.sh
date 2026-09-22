#!/usr/bin/env bash
# Step 11: prove the logging isolation, end to end.
#   ok   = must work          fail = must be blocked / refused
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
require_cluster
ensure_credentials
command -v jq >/dev/null || die "jq is required"

GRAFANA_ADMIN_PASSWORD="$(kubectl -n "${OBS_NS}" get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
G_PORT="${G_PORT:-33000}"
GW_PORT="${GW_PORT:-38080}"
G="http://127.0.0.1:${G_PORT}"
GW="http://127.0.0.1:${GW_PORT}/loki/api/v1"

# Admin's view: port-forwards go straight into the pod's network namespace,
# so they test the application logic (auth, orgs), not the network policy.
PIDS=()
cleanup() {
  kill "${PIDS[@]}" 2>/dev/null || true
  kubectl -n default delete pod st-probe --now --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${OBS_NS}" delete pod st-l7-probe --now --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
kubectl -n "${OBS_NS}" port-forward svc/grafana "${G_PORT}:80" >/dev/null 2>&1 & PIDS+=($!)
kubectl -n "${OBS_NS}" port-forward svc/loki-gateway "${GW_PORT}:8080" >/dev/null 2>&1 & PIDS+=($!)
for _ in $(seq 1 30); do
  curl -sf "${G}/api/health" >/dev/null 2>&1 && curl -sf "http://127.0.0.1:${GW_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 1
done

A="alice:${GRAFANA_PW_ALICE}"; B="bob:${GRAFANA_PW_BOB}"; O="ops:${GRAFANA_PW_OPS}"
ns_seen_by() {  # ns_seen_by <user:pw> <datasource uid>: namespaces visible through Grafana
  curl -sf -u "$1" "${G}/api/datasources/uid/$2/resources/label/namespace/values" | jq -c '.data // []'
}
json() { jq -e "$2" <<<"$1"; }   # json <document> <jq assertion>

log "Waiting for tenant logs to show up (Alloy ships every few seconds)..."
for _ in $(seq 1 24); do
  json "$(ns_seen_by "$A" loki-tenant-a 2>/dev/null || echo '[]')" 'index("tenant-a")' >/dev/null 2>&1 && break
  sleep 5
done

SEEN_A="$(ns_seen_by "$A" loki-tenant-a || echo '[]')"
SEEN_B="$(ns_seen_by "$B" loki-tenant-b || echo '[]')"
SEEN_O="$(ns_seen_by "$O" loki-platform || echo '[]')"
log "alice sees ${SEEN_A} | bob sees ${SEEN_B} | ops sees ${SEEN_O}"

echo; log "── Grafana: each user sees only their tenant"
check "alice sees tenant-a, and only tenant-a"      ok   json "$SEEN_A" 'length > 0 and all(.[]; test("^tenant-a(-|$)"))'
check "bob sees tenant-b, and only tenant-b"        ok   json "$SEEN_B" 'length > 0 and all(.[]; test("^tenant-b(-|$)"))'
check "ops sees platform logs, no tenant's"         ok   json "$SEEN_O" 'index("kube-system") and all(.[]; test("^tenant-(a|b)(-|$)") | not)'
check "alice's only org is 'Tenant A' (Editor)"     ok   json "$(curl -sf -u "$A" "${G}/api/user/orgs")" \
                                                          'length == 1 and .[0].name == "Tenant A" and .[0].role == "Editor"'
ORG_B="$(curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD}" "${G}/api/orgs/name/Tenant%20B" | jq -r .id)"
check "alice can't use bob's data source"           fail curl -sf -u "$A" "${G}/api/datasources/uid/loki-tenant-b/resources/label/namespace/values"
check "alice can't switch to org 'Tenant B'"        fail curl -sf -u "$A" -X POST "${G}/api/user/using/${ORG_B}"
check "alice can't pick 'Tenant B' via header"      fail curl -sf -u "$A" -H "X-Grafana-Org-Id: ${ORG_B}" \
                                                          "${G}/api/datasources/uid/loki-tenant-b/resources/label/namespace/values"
check "alice can't create a data source"            fail curl -sf -u "$A" -X POST -H 'Content-Type: application/json' \
      -d '{"name":"evil","type":"loki","access":"proxy","url":"http://loki.observability.svc.cluster.local:3100"}' \
      "${G}/api/datasources"
check "Main Org has no data sources"                ok   json "$(curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
                                                          -H 'X-Grafana-Org-Id: 1' "${G}/api/datasources")" 'length == 0'

echo; log "── Gateway: the tenant comes from the password, never the header"
gw_ns() { curl -sf -u "$1" "${@:2}" "${GW}/label/namespace/values" | jq -c '.data // []'; }
check "no credentials -> refused"                   fail curl -sf "${GW}/label/namespace/values"
check "wrong password -> refused"                   fail curl -sf -u tenant-a:wrong "${GW}/label/namespace/values"
check "tenant-a claiming X-Scope-OrgID: tenant-b"   ok   json "$(gw_ns "tenant-a:${LOKI_PW_TENANT_A}" -H 'X-Scope-OrgID: tenant-b')" \
                                                          'length > 0 and all(.[]; test("^tenant-a(-|$)"))'
check "tenant-a claiming tenant-a|tenant-b"         ok   json "$(gw_ns "tenant-a:${LOKI_PW_TENANT_A}" -H 'X-Scope-OrgID: tenant-a|tenant-b')" \
                                                          'all(.[]; test("^tenant-a(-|$)"))'
check "push through the gateway -> refused"         fail curl -sf -u "tenant-a:${LOKI_PW_TENANT_A}" -X POST \
                                                          -H 'Content-Type: application/json' -d '{"streams":[]}' "${GW}/push"

echo; log "── Network: only Alloy and the gateway reach Loki"
svc_ip() { kubectl -n "${OBS_NS}" get svc "$1" -o jsonpath='{.spec.clusterIP}'; }
LOKI_IP="$(svc_ip loki)"; GW_IP="$(svc_ip loki-gateway)"; GRAFANA_IP="$(svc_ip grafana)"
# By IP on purpose: tenant DNS would already refuse these names, and we want
# to prove the packets themselves are dropped.
check "tenant-a -> Loki ${LOKI_IP}:3100"            fail in_tenant tenant-a "curl -s -m 3 -o /dev/null http://${LOKI_IP}:3100/ready"
check "tenant-a -> gateway ${GW_IP}:8080"           fail in_tenant tenant-a "curl -s -m 3 -o /dev/null http://${GW_IP}:8080/healthz"
check "tenant-a -> Grafana ${GRAFANA_IP}:80"        fail in_tenant tenant-a "curl -s -m 3 -o /dev/null http://${GRAFANA_IP}/api/health"

run_probe() {  # run_probe <namespace> <pod> [extra kubectl run args]: sleeping netshoot pod
  local ns=$1 pod=$2
  shift 2
  kubectl -n "$ns" delete pod "$pod" --now --ignore-not-found >/dev/null
  # Strategic merge: our securityContext merges into the generated container
  # (same name as the pod) instead of replacing it.
  kubectl -n "$ns" run "$pod" --restart=Never --image=docker.io/nicolaka/netshoot:v0.16 "$@" \
    --override-type=strategic --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"automountServiceAccountToken\":false,
      \"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65534,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},
      \"containers\":[{\"name\":\"${pod}\",\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" \
    --command -- sleep 600 >/dev/null
  kubectl -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
}
run_probe default st-probe
probe() { kubectl -n default exec st-probe -- sh -c "$1"; }
check "pod in 'default' -> Loki (the attack)"       fail probe "curl -s -m 3 -o /dev/null http://${LOKI_IP}:3100/ready"
check "pod in 'default' -> gateway"                 fail probe "curl -s -m 3 -o /dev/null http://${GW_IP}:8080/healthz"
check "pod in 'default' -> Grafana"                 fail probe "curl -s -m 3 -o /dev/null http://${GRAFANA_IP}/api/health"

# A pod wearing Alloy's label gets exactly Alloy's rights: push, but no reads.
run_probe "${OBS_NS}" st-l7-probe --labels=app.kubernetes.io/name=alloy
l7() { kubectl -n "${OBS_NS}" exec st-l7-probe -- curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; }
code_is() { [[ "$1" == "$2" ]]; }
NOW_NS="$(date +%s)000000000"
check "Alloy identity: push to Loki is allowed"     ok   code_is 204 "$(l7 -X POST -H 'X-Scope-OrgID: platform' \
      -H 'Content-Type: application/json' \
      -d "{\"streams\":[{\"stream\":{\"namespace\":\"l7-probe\"},\"values\":[[\"${NOW_NS}\",\"l7 probe\"]]}]}" \
      "http://${LOKI_IP}:3100/loki/api/v1/push" || true)"
check "Alloy identity: reading from Loki -> 403"    ok   code_is 403 "$(l7 -H 'X-Scope-OrgID: tenant-b' \
      "http://${LOKI_IP}:3100/loki/api/v1/label/namespace/values" || true)"

summary

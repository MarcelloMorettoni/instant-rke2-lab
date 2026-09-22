#!/usr/bin/env bash
# Step 11: prove the observability isolation, end to end, for all four signals.
#   ok   = must work          fail = must be blocked / refused
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
require_cluster
ensure_credentials
command -v jq >/dev/null || die "jq is required"

GRAFANA_ADMIN_PASSWORD="$(kubectl -n "${OBS_NS}" get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
G="http://127.0.0.1:33000"
GW="http://127.0.0.1"                 # obs-gateway: :43100 Loki :48080 Mimir :43200 Tempo :44040 Pyroscope

# Admin's view: port-forwards go straight into the pod's network namespace,
# so they test the application logic (auth, orgs), not the network policy.
PIDS=()
cleanup() {
  kill "${PIDS[@]}" 2>/dev/null || true
  kubectl -n default delete pod st-probe --now --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${OBS_NS}" delete pod st-l7-probe --now --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
kubectl -n "${OBS_NS}" port-forward svc/grafana 33000:80 >/dev/null 2>&1 & PIDS+=($!)
kubectl -n "${OBS_NS}" port-forward svc/obs-gateway 43100:3100 48080:8080 43200:3200 44040:4040 >/dev/null 2>&1 & PIDS+=($!)
for _ in $(seq 1 30); do
  # The gateway has no open endpoint: a 401 on a real API path means it is up.
  curl -sf "${G}/api/health" >/dev/null 2>&1 &&
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "${GW}:43100/loki/api/v1/labels")" == 401 ]] && break
  sleep 1
done

# Each tenant's gateway key, as a curl header. The key alone decides the tenant.
TA="X-Api-Key: ${OBS_KEY_TENANT_A}"; TB="X-Api-Key: ${OBS_KEY_TENANT_B}"
A="alice:${GRAFANA_PW_ALICE}"; B="bob:${GRAFANA_PW_BOB}"; O="ops:${GRAFANA_PW_OPS}"
json() { jq -e "$2" <<<"$1"; }                       # json <document> <jq assertion>
ms_range() { local now; now=$(date +%s); echo "start=$(( (now - 3600) * 1000 ))&end=$(( now * 1000 ))"; }
only() { printf 'length > 0 and all(.[]; test("^%s(-|$)"))' "$1"; }   # every namespace is tenant X's

# ---- what each tenant sees, through the gateway, per signal ----------------
gw_logs()     { curl -sf -H "$1" "${@:2}" "${GW}:43100/loki/api/v1/label/namespace/values" | jq -c '.data // []'; }
gw_metrics()  { curl -sf -H "$1" "${@:2}" "${GW}:48080/prometheus/api/v1/label/namespace/values" | jq -c '.data // []'; }
gw_profiles() { local now; now=$(date +%s)
  curl -sf -H "$1" "${@:2}" -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"namespace\",\"start\":$(( (now - 3600) * 1000 )),\"end\":$(( now * 1000 ))}" \
    "${GW}:44040/querier.v1.QuerierService/LabelValues" | jq -c '.names // []'; }
gw_trace_ids() { curl -sf -H "$1" "${GW}:43200/api/search?limit=20" | jq -r '.traces[]?.traceID'; }
gw_trace_spans() {  # number of resource spans a user gets back for a trace id (0 on any error)
  curl -sf -H "$1" "${@:3}" "${GW}:43200/api/v2/traces/$2" 2>/dev/null | jq '[.trace.resourceSpans[]?] | length' 2>/dev/null || echo 0; }

log "Waiting for all four signals of tenant-a (Alloy scrapes every 30s, profiles need a minute)..."
for _ in $(seq 1 36); do
  if json "$(gw_logs "$TA" 2>/dev/null || echo '[]')" 'index("tenant-a")' >/dev/null 2>&1 &&
     json "$(gw_metrics "$TA" 2>/dev/null || echo '[]')" 'index("tenant-a")' >/dev/null 2>&1 &&
     json "$(gw_profiles "$TA" 2>/dev/null || echo '[]')" 'index("tenant-a")' >/dev/null 2>&1 &&
     [[ -n "$(gw_trace_ids "$TA" 2>/dev/null)" ]]; then break; fi
  sleep 5
done
# "|| true": a failing lookup must turn into FAILed checks below, not a silent exit.
A_TRACE="$(gw_trace_ids "$TA" 2>/dev/null | head -1 || true)"; A_TRACE="${A_TRACE:-none}"
B_TRACE="$(gw_trace_ids "$TB" 2>/dev/null | head -1 || true)"; B_TRACE="${B_TRACE:-none}"

echo; log "── Each tenant sees only itself, on every backend"
check "logs:     tenant-a sees only tenant-a"             ok   json "$(gw_logs "$TA")" "$(only tenant-a)"
check "logs:     tenant-b sees only tenant-b"             ok   json "$(gw_logs "$TB")" "$(only tenant-b)"
check "metrics:  tenant-a sees only tenant-a"             ok   json "$(gw_metrics "$TA")" "$(only tenant-a)"
check "metrics:  tenant-b sees only tenant-b"             ok   json "$(gw_metrics "$TB")" "$(only tenant-b)"
check "profiles: tenant-a sees only tenant-a"             ok   json "$(gw_profiles "$TA")" "$(only tenant-a)"
check "profiles: tenant-b sees only tenant-b"             ok   json "$(gw_profiles "$TB")" "$(only tenant-b)"
check "traces:   tenant-a gets its own trace"             ok   test "$(gw_trace_spans "$TA" "$A_TRACE")" -gt 0
check "traces:   tenant-b gets nothing for it"            ok   test "$(gw_trace_spans "$TB" "$A_TRACE")" -eq 0
check "traces:   tenant-a gets nothing for tenant-b's"    ok   test "$(gw_trace_spans "$TA" "$B_TRACE")" -eq 0

echo; log "── The tenant comes from the key, never the header"
SPOOF=(-H 'X-Scope-OrgID: tenant-b')
check "logs:     tenant-a claiming tenant-b"              ok   json "$(gw_logs "$TA" "${SPOOF[@]}")" "$(only tenant-a)"
check "metrics:  tenant-a claiming tenant-b"              ok   json "$(gw_metrics "$TA" "${SPOOF[@]}")" "$(only tenant-a)"
check "profiles: tenant-a claiming tenant-b"              ok   json "$(gw_profiles "$TA" "${SPOOF[@]}")" "$(only tenant-a)"
check "traces:   tenant-a claiming tenant-b"              ok   test "$(gw_trace_spans "$TA" "$B_TRACE" "${SPOOF[@]}")" -eq 0
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# A real API path of each backend: auth runs per route, so an unrouted path is just 404.
for probe in "43100 Loki /loki/api/v1/labels" "48080 Mimir /prometheus/api/v1/labels" \
             "43200 Tempo /api/search" "44040 Pyroscope /querier.v1.QuerierService/ProfileTypes"; do
  read -r port name path <<<"$probe"
  check "no key (${name}) -> 401"                           ok   test "$(http_code "${GW}:${port}${path}")" = 401
  check "unknown key (${name}) -> 401"                      ok   test "$(http_code -H 'X-Api-Key: not-a-key' "${GW}:${port}${path}")" = 401
done
check "Loki push through the gateway -> refused"          fail curl -sf -H "$TA" -X POST -H 'Content-Type: application/json' -d '{"streams":[]}' "${GW}:43100/loki/api/v1/push"
check "Mimir push through the gateway -> refused"         fail curl -sf -H "$TA" -X POST -d x "${GW}:48080/api/v1/push"
check "Tempo overrides API -> refused"                    fail curl -sf -H "$TA" "${GW}:43200/api/overrides"
check "Pyroscope push through the gateway -> refused"     fail curl -sf -H "$TA" -X POST -d x "${GW}:44040/push.v1.PusherService/Push"

echo; log "── Signals are linked, inside a tenant only"
LOG_TRACE="$(curl -sf -H "$TA" -G "${GW}:43100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="tenant-a", container="frontend"} |= "trace_id"' --data-urlencode limit=1 \
  | jq -r '.data.result[0].values[0][1] // ""' | grep -o '"trace_id":"[a-f0-9]*"' | cut -d'"' -f4 || true)"
check "a tenant-a log line's trace_id opens in Tempo"     ok   test "$(gw_trace_spans "$TA" "${LOG_TRACE:-none}")" -gt 0
check "...but not for tenant-b"                           ok   test "$(gw_trace_spans "$TB" "${LOG_TRACE:-none}")" -eq 0
SG='sum by (client, server) (traces_service_graph_request_total{client="frontend", server="backend"})'
check "service graph frontend -> backend (tenant-a)"      ok   json "$(curl -sf -H "$TA" --data-urlencode "query=${SG}" "${GW}:48080/prometheus/api/v1/query")" '.data.result | length > 0'
check "podinfo request metrics (tenant-a)"                ok   json "$(curl -sf -H "$TA" --data-urlencode 'query=count(http_request_duration_seconds_count{namespace="tenant-a"})' "${GW}:48080/prometheus/api/v1/query")" '.data.result | length > 0'

echo; log "── Grafana: each user in their own org, with four linked data sources"
check "alice's only org is 'Tenant A' (Editor)"           ok   json "$(curl -sf -u "$A" "${G}/api/user/orgs")" 'length == 1 and .[0].name == "Tenant A" and .[0].role == "Editor"'
check "alice: logs are tenant-a only"                     ok   json "$(curl -sf -u "$A" "${G}/api/datasources/uid/loki-tenant-a/resources/label/namespace/values" | jq -c '.data // []')" "$(only tenant-a)"
check "alice: metrics are tenant-a only"                  ok   json "$(curl -sf -u "$A" "${G}/api/datasources/uid/mimir-tenant-a/resources/api/v1/label/namespace/values" | jq -c '.data // []')" "$(only tenant-a)"
check "alice: profiles are tenant-a only"                 ok   json "$(curl -sf -u "$A" "${G}/api/datasources/uid/pyroscope-tenant-a/resources/labelValues?label=namespace&query=%7B%7D&$(ms_range)")" "$(only tenant-a)"
check "bob: metrics are tenant-b only"                    ok   json "$(curl -sf -u "$B" "${G}/api/datasources/uid/mimir-tenant-b/resources/api/v1/label/namespace/values" | jq -c '.data // []')" "$(only tenant-b)"
check "ops: platform metrics, no tenant's"                ok   json "$(curl -sf -u "$O" "${G}/api/datasources/uid/mimir-platform/resources/api/v1/label/namespace/values" | jq -c '.data // []')" 'all(.[]; test("^tenant-(a|b)(-|$)") | not)'
for ds in loki mimir tempo pyroscope; do
  check "alice can't use bob's ${ds} data source"          fail curl -sf -u "$A" "${G}/api/datasources/uid/${ds}-tenant-b"
done
check "alice can't create a data source"                  fail curl -sf -u "$A" -X POST -H 'Content-Type: application/json' \
      -d '{"name":"evil","type":"prometheus","access":"proxy","url":"http://mimir.observability.svc.cluster.local:8080/prometheus"}' "${G}/api/datasources"
check "Main Org has no data sources"                      ok   json "$(curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD}" -H 'X-Grafana-Org-Id: 1' "${G}/api/datasources")" 'length == 0'

echo; log "── Network: who may reach what"
svc_ip() { kubectl -n "${OBS_NS}" get svc "$1" -o jsonpath='{.spec.clusterIP}'; }
LOKI_IP="$(svc_ip loki)"; MIMIR_IP="$(svc_ip mimir)"; TEMPO_IP="$(svc_ip tempo)"; PYRO_IP="$(svc_ip pyroscope)"
GW_IP="$(svc_ip obs-gateway)"; OTLP_A="$(svc_ip otlp-tenant-a)"; OTLP_B="$(svc_ip otlp-tenant-b)"
# By IP on purpose: tenant DNS would already hide these names; we want to
# prove the packets themselves are dropped.
tcp() { in_tenant "$1" "nc -z -w 3 $2 $3"; }
check "tenant-a -> its own trace receiver"                ok   tcp tenant-a "$OTLP_A" 4317
check "tenant-a -> tenant-b's trace receiver"             fail tcp tenant-a "$OTLP_B" 4317
check "tenant-b -> tenant-a's trace receiver"             fail tcp tenant-b "$OTLP_A" 4317
check "tenant-a -> Tempo directly"                        fail tcp tenant-a "$TEMPO_IP" 4317
check "tenant-a -> Mimir"                                 fail tcp tenant-a "$MIMIR_IP" 8080
check "tenant-a -> Loki"                                  fail tcp tenant-a "$LOKI_IP" 3100
check "tenant-a -> Pyroscope"                             fail tcp tenant-a "$PYRO_IP" 4040
check "tenant-a -> the read gateway"                      fail tcp tenant-a "$GW_IP" 8080

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
check "pod in 'default' -> Mimir (the attack)"            fail probe "nc -z -w 3 ${MIMIR_IP} 8080"
check "pod in 'default' -> Tempo"                         fail probe "nc -z -w 3 ${TEMPO_IP} 3200"
check "pod in 'default' -> Loki"                          fail probe "nc -z -w 3 ${LOKI_IP} 3100"
check "pod in 'default' -> Pyroscope"                     fail probe "nc -z -w 3 ${PYRO_IP} 4040"
check "pod in 'default' -> a trace receiver"              fail probe "nc -z -w 3 ${OTLP_A} 4317"

# A pod wearing Alloy's label gets exactly Alloy's rights: push, but no reads.
run_probe "${OBS_NS}" st-l7-probe --labels=app.kubernetes.io/name=alloy
code() { kubectl -n "${OBS_NS}" exec st-l7-probe -- curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" || true; }
is() { [[ "$1" == "$2" ]]; }
not() { [[ "$1" != "$2" ]]; }
check "Alloy identity: Mimir push passes the L7 rule"     ok   not 403 "$(code -X POST -H 'X-Scope-OrgID: platform' -d x "http://${MIMIR_IP}:8080/api/v1/push")"
check "Alloy identity: Mimir query -> 403"                ok   is 403 "$(code -H 'X-Scope-OrgID: tenant-b' "http://${MIMIR_IP}:8080/prometheus/api/v1/labels")"
check "Alloy identity: Loki query -> 403"                 ok   is 403 "$(code -H 'X-Scope-OrgID: tenant-b' "http://${LOKI_IP}:3100/loki/api/v1/labels")"
check "Alloy identity: Pyroscope query -> 403"            ok   is 403 "$(code -X POST -H 'X-Scope-OrgID: tenant-b' -H 'Content-Type: application/json' -d '{}' "http://${PYRO_IP}:4040/querier.v1.QuerierService/ProfileTypes")"

summary

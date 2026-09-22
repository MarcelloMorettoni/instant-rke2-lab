#!/usr/bin/env bash
# Step 11: prove the observability isolation, end to end, for all four signals.
#   ok   = must work          fail = must be blocked / refused
#
#   Grafana org (view)   sees
#   Tenant A  /tenant-a/  tenant-a, tenant-c
#   Tenant B  /tenant-b/  tenant-b
#   Tenant C  /tenant-c/  tenant-c
#   Platform  /platform/  everything
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
require_cluster
ensure_credentials
command -v jq >/dev/null || die "jq is required"

G="http://127.0.0.1:33000"
GW="http://127.0.0.1:48080"           # obs-gateway :8080; every path starts with a view

# Admin's view: port-forwards go straight into the pod's network namespace,
# so they test the application logic (keys, views, orgs), not the network policy.
PIDS=()
cleanup() {
  kill "${PIDS[@]}" 2>/dev/null || true
  kubectl -n default delete pod st-probe --now --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${OBS_NS}" delete pod st-l7-probe --now --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
kubectl -n "${OBS_NS}" port-forward svc/grafana 33000:80 >/dev/null 2>&1 & PIDS+=($!)
kubectl -n "${OBS_NS}" port-forward svc/obs-gateway 48080:8080 >/dev/null 2>&1 & PIDS+=($!)
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
for _ in $(seq 1 30); do
  # The gateway has no open endpoint: a 401 on a view means it is up.
  curl -sf "${G}/api/health" >/dev/null 2>&1 &&
    [[ "$(http_code "${GW}/tenant-a/loki/api/v1/labels")" == 401 ]] && break
  sleep 1
done

A="alice:${ST_PASSWORD}"; B="bob:${ST_PASSWORD}"; C="carol:${ST_PASSWORD}"; O="ops:${ST_PASSWORD}"
key() { local v="OBS_KEY_$(tr 'a-z-' 'A-Z_' <<<"$1")"; echo "X-Api-Key: ${!v}"; }   # key <view>
json() { jq -e "$2" <<<"$1"; }                       # json <document> <jq assertion>
ms_range() { local now; now=$(date +%s); echo "start=$(( (now - 3600) * 1000 ))&end=$(( now * 1000 ))"; }
tenant_ns() { printf 'select(test("^tenant-[a-z0-9]+(-|$)")) | capture("^(?<t>tenant-[a-z0-9]+)").t'; }
# exactly <view tenants>: the tenant namespaces seen are exactly this set
exactly() { printf '[.[] | %s] | unique == %s' "$(tenant_ns)" "$(jq -cn '$ARGS.positional | sort' --args "$@")"; }

# ---- what each view sees, through the gateway, per signal ------------------
gw_logs()     { curl -sf -H "$(key "$1")" "${@:2}" "${GW}/$1/loki/api/v1/label/namespace/values" | jq -c '.data // []'; }
gw_metrics()  { curl -sf -H "$(key "$1")" "${@:2}" "${GW}/$1/prometheus/api/v1/label/namespace/values" | jq -c '.data // []'; }
gw_profiles() { local now; now=$(date +%s)          # gw_profiles <view> <tenant>
  curl -sf -H "$(key "$1")" -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"namespace\",\"start\":$(( (now - 3600) * 1000 )),\"end\":$(( now * 1000 ))}" \
    "${GW}/$1/pyroscope/$2/querier.v1.QuerierService/LabelValues" | jq -c '.names // []'; }
# Traces younger than a minute may still be on their way to Tempo: leave them out.
gw_traces()   { curl -sf -H "$(key "$1")" "${GW}/$1/api/search?limit=100" |
                jq -c '[.traces[]? | select((.startTimeUnixNano | tonumber) / 1e9 < now - 60)
                        | {id: .traceID, root: .rootServiceName}]'; }
# gw_trace_tenants <view> <trace id> [curl args]: the "tenant" stamps on the spans the view gets back
gw_trace_tenants() {
  curl -sf -H "$(key "$1")" "${@:3}" "${GW}/$1/api/v2/traces/$2" 2>/dev/null |
    jq -c '[.trace.resourceSpans[]?.resource.attributes[]? | select(.key == "tenant") | .value.stringValue] | unique' 2>/dev/null || echo '[]'; }

# A demo request (/echo) logged by tenant a's frontend over a minute ago: its trace is in Tempo.
log_trace() {
  local end=$(( ($(date +%s) - 60) * 1000000000 ))
  curl -sf -H "$(key tenant-a)" -G "${GW}/tenant-a/loki/api/v1/query_range" \
    --data-urlencode 'query={namespace="tenant-a", container="frontend"} |= "trace_id" |= `"uri":"/echo"`' \
    --data-urlencode limit=1 --data-urlencode "end=${end}" --data-urlencode "start=$(( end - 600000000000 ))" \
    | jq -r '.data.result[0].values[0][1] // ""' | grep -o '"trace_id":"[a-f0-9]*"' | cut -d'"' -f4 || true
}
pick() { jq -r "$1" <<<"$2" | head -1; }

# The traces the checks use, found through the views that can only hold them:
#   CROSS      tenant a's frontend calling tenant c's backend. In tenant c it
#              has no root span (that lives in tenant a).
#   C_TRACE    tenant c's own frontend -> backend
#   B_TRACE    tenant b's own
#   LOG_TRACE  the trace_id in one of tenant a's log lines
# Right after an install, Tempo needs a few minutes before it answers every
# multi-tenant lookup, so wait until the expected answers come back, then check.
log "Waiting for all signals of tenants a, b and c (Alloy scrapes every 30s, profiles need a minute)..."
CROSS=none; C_TRACE=none; B_TRACE=none; LOG_TRACE=none
for _ in $(seq 1 60); do
  if json "$(gw_logs platform 2>/dev/null || echo '[]')" "$(exactly tenant-a tenant-b tenant-c)" >/dev/null 2>&1 &&
     json "$(gw_metrics platform 2>/dev/null || echo '[]')" "$(exactly tenant-a tenant-b tenant-c)" >/dev/null 2>&1 &&
     json "$(gw_profiles tenant-a tenant-c 2>/dev/null || echo '[]')" 'index("tenant-c")' >/dev/null 2>&1; then
    C_TRACES="$(gw_traces tenant-c 2>/dev/null || echo '[]')"
    CROSS="$(pick 'map(select(.root | test("root span")))[0].id // "none"' "${C_TRACES}")"
    C_TRACE="$(pick 'map(select(.root == "frontend"))[0].id // "none"' "${C_TRACES}")"
    B_TRACE="$(pick '.[0].id // "none"' "$(gw_traces tenant-b 2>/dev/null || echo '[]')")"
    LOG_TRACE="$(log_trace)"; LOG_TRACE="${LOG_TRACE:-none}"
    json "$(gw_trace_tenants tenant-a "${CROSS}")" 'length == 2' >/dev/null 2>&1 &&
      json "$(gw_trace_tenants tenant-a "${C_TRACE}")" 'length == 1' >/dev/null 2>&1 &&
      json "$(gw_trace_tenants platform "${B_TRACE}")" 'length == 1' >/dev/null 2>&1 &&
      json "$(gw_trace_tenants tenant-a "${LOG_TRACE}")" 'length > 0' >/dev/null 2>&1 && break
  fi
  sleep 5
done

echo; log "── Logs and metrics: each view sees exactly its tenants"
for v in "tenant-a:tenant-a tenant-c" "tenant-b:tenant-b" "tenant-c:tenant-c" "platform:tenant-a tenant-b tenant-c"; do
  view="${v%%:*}"; read -r -a want <<<"${v#*:}"
  check "logs:     /${view}/ sees ${want[*]}"                   ok json "$(gw_logs "${view}")" "$(exactly "${want[@]}")"
  check "metrics:  /${view}/ sees ${want[*]}"                   ok json "$(gw_metrics "${view}")" "$(exactly "${want[@]}")"
done
check "logs:     /platform/ also sees the platform's own"   ok   json "$(gw_logs platform)" 'index("kube-system") and index("observability")'
check "metrics:  results carry __tenant_id__ (a|c)"         ok   json "$(curl -sf -H "$(key tenant-a)" --data-urlencode 'query=count by (__tenant_id__) (up)' "${GW}/tenant-a/prometheus/api/v1/query")" \
      '[.data.result[].metric.__tenant_id__] | sort == ["tenant-a","tenant-c"]'

echo; log "── Profiles: one path per tenant (Pyroscope has no multi-tenant queries)"
check "profiles: /tenant-a/ -> tenant-a's profiles only"    ok   json "$(gw_profiles tenant-a tenant-a)" "$(exactly tenant-a)"
check "profiles: /tenant-a/ -> tenant-c's profiles only"    ok   json "$(gw_profiles tenant-a tenant-c)" "$(exactly tenant-c)"
check "profiles: /platform/ -> tenant-b's profiles"         ok   json "$(gw_profiles platform tenant-b)" "$(exactly tenant-b)"
check "profiles: /tenant-c/ has no path to tenant-a"        fail gw_profiles tenant-c tenant-a
check "profiles: /tenant-b/ has no path to tenant-c"        fail gw_profiles tenant-b tenant-c

echo; log "── Traces"
check "traces:   /tenant-a/ gets a cross-tenant trace whole" ok  json "$(gw_trace_tenants tenant-a "${CROSS}")" '. == ["tenant-a","tenant-c"]'
check "traces:   /tenant-c/ gets only its half of it"        ok  json "$(gw_trace_tenants tenant-c "${CROSS}")" '. == ["tenant-c"]'
check "traces:   /tenant-b/ gets nothing of it"              ok  json "$(gw_trace_tenants tenant-b "${CROSS}")" '. == []'
check "traces:   /tenant-a/ gets tenant-c's own traces"      ok  json "$(gw_trace_tenants tenant-a "${C_TRACE}")" '. == ["tenant-c"]'
check "traces:   /tenant-a/ gets nothing of tenant b"       ok  json "$(gw_trace_tenants tenant-a "${B_TRACE}")" '. == []'
check "traces:   /tenant-c/ gets nothing of tenant b"       ok  json "$(gw_trace_tenants tenant-c "${B_TRACE}")" '. == []'
check "traces:   /platform/ gets tenant-b's traces"          ok  json "$(gw_trace_tenants platform "${B_TRACE}")" '. == ["tenant-b"]'

echo; log "── A key opens its own view, and nothing else"
check "no key -> 401"                                       ok   test "$(http_code "${GW}/tenant-a/loki/api/v1/labels")" = 401
check "unknown key -> 401"                                  ok   test "$(http_code -H 'X-Api-Key: not-a-key' "${GW}/tenant-a/loki/api/v1/labels")" = 401
check "tenant-a's key on /tenant-b/ -> 401"                 ok   test "$(http_code -H "$(key tenant-a)" "${GW}/tenant-b/loki/api/v1/labels")" = 401
check "tenant-c's key on /tenant-a/ -> 401"                 ok   test "$(http_code -H "$(key tenant-c)" "${GW}/tenant-a/loki/api/v1/labels")" = 401
check "tenant-b's key on /platform/ -> 401"                 ok   test "$(http_code -H "$(key tenant-b)" "${GW}/platform/prometheus/api/v1/labels")" = 401
check "path trick /tenant-a/../tenant-b/ -> 401"            ok   test "$(http_code --path-as-is -H "$(key tenant-a)" "${GW}/tenant-a/../tenant-b/loki/api/v1/labels")" = 401
check "logs:     tenant-c claiming tenant-a (header)"       ok   json "$(gw_logs tenant-c -H 'X-Scope-OrgID: tenant-a')" "$(exactly tenant-c)"
check "metrics:  tenant-c claiming a|c (header)"            ok   json "$(gw_metrics tenant-c -H 'X-Scope-OrgID: tenant-a|tenant-c')" "$(exactly tenant-c)"
check "traces:   tenant-c claiming a|c (header)"            ok   json "$(gw_trace_tenants tenant-c "${CROSS}" -H 'X-Scope-OrgID: tenant-a|tenant-c')" '. == ["tenant-c"]'
check "Loki push through the gateway -> 403"                ok   test "$(http_code -H "$(key tenant-a)" -X POST -H 'Content-Type: application/json' -d '{"streams":[]}' "${GW}/tenant-a/loki/api/v1/push")" = 403
check "Tempo overrides API -> 403"                          ok   test "$(http_code -H "$(key tenant-a)" "${GW}/tenant-a/api/overrides")" = 403
check "Mimir push through the gateway -> refused"           fail curl -sf -H "$(key tenant-a)" -X POST -d x "${GW}/tenant-a/prometheus/api/v1/push"
check "Pyroscope push through the gateway -> refused"       fail curl -sf -H "$(key tenant-a)" -X POST -d x "${GW}/tenant-a/pyroscope/tenant-a/push.v1.PusherService/Push"

echo; log "── Signals are linked, inside a view only"
check "a tenant-a log line's trace_id opens in /tenant-a/"  ok   json "$(gw_trace_tenants tenant-a "${LOG_TRACE}")" 'index("tenant-a")'
check "...but not in /tenant-b/"                            ok   json "$(gw_trace_tenants tenant-b "${LOG_TRACE}")" '. == []'
SG='sum by (client, server) (traces_service_graph_request_total{client="frontend", server="backend"})'
check "service graph frontend -> backend (/tenant-a/)"      ok   json "$(curl -sf -H "$(key tenant-a)" --data-urlencode "query=${SG}" "${GW}/tenant-a/prometheus/api/v1/query")" '.data.result | length > 0'
check "podinfo request metrics (/tenant-c/)"                ok   json "$(curl -sf -H "$(key tenant-c)" --data-urlencode 'query=count(http_request_duration_seconds_count{namespace="tenant-c"})' "${GW}/tenant-c/prometheus/api/v1/query")" '.data.result | length > 0'

echo; log "── Grafana: each user in their own org (password: ${ST_PASSWORD})"
check "alice's only org is 'Tenant A' (Editor)"             ok   json "$(curl -sf -u "$A" "${G}/api/user/orgs")" 'length == 1 and .[0].name == "Tenant A" and .[0].role == "Editor"'
check "carol's only org is 'Tenant C' (Editor)"             ok   json "$(curl -sf -u "$C" "${G}/api/user/orgs")" 'length == 1 and .[0].name == "Tenant C" and .[0].role == "Editor"'
check "alice: logs are tenant-a and tenant-c"               ok   json "$(curl -sf -u "$A" "${G}/api/datasources/uid/loki-tenant-a/resources/label/namespace/values" | jq -c '.data // []')" "$(exactly tenant-a tenant-c)"
check "alice: metrics are tenant-a and tenant-c"            ok   json "$(curl -sf -u "$A" "${G}/api/datasources/uid/mimir-tenant-a/resources/api/v1/label/namespace/values" | jq -c '.data // []')" "$(exactly tenant-a tenant-c)"
check "alice: 'Pyroscope (tenant-c)' is tenant-c only"      ok   json "$(curl -sf -u "$A" "${G}/api/datasources/uid/pyroscope-tenant-a-tenant-c/resources/labelValues?label=namespace&query=%7B%7D&$(ms_range)")" "$(exactly tenant-c)"
check "bob: metrics are tenant-b only"                      ok   json "$(curl -sf -u "$B" "${G}/api/datasources/uid/mimir-tenant-b/resources/api/v1/label/namespace/values" | jq -c '.data // []')" "$(exactly tenant-b)"
check "carol: logs are tenant-c only"                       ok   json "$(curl -sf -u "$C" "${G}/api/datasources/uid/loki-tenant-c/resources/label/namespace/values" | jq -c '.data // []')" "$(exactly tenant-c)"
check "ops: metrics are everyone's"                         ok   json "$(curl -sf -u "$O" "${G}/api/datasources/uid/mimir-platform/resources/api/v1/label/namespace/values" | jq -c '.data // []')" "$(exactly tenant-a tenant-b tenant-c)"
for ds in loki-tenant-b mimir-tenant-b tempo-tenant-b pyroscope-tenant-b loki-tenant-c pyroscope-platform; do
  check "alice can't use ${ds}"                             fail curl -sf -u "$A" "${G}/api/datasources/uid/${ds}"
done
check "carol can't use tenant a's data sources"             fail curl -sf -u "$C" "${G}/api/datasources/uid/loki-tenant-a"
check "alice can't create a data source"                    fail curl -sf -u "$A" -X POST -H 'Content-Type: application/json' \
      -d '{"name":"evil","type":"prometheus","access":"proxy","url":"http://mimir.observability.svc.cluster.local:8080/prometheus"}' "${G}/api/datasources"
check "Main Org has no data sources"                        ok   json "$(curl -sf -u "admin:${ST_PASSWORD}" -H 'X-Grafana-Org-Id: 1' "${G}/api/datasources")" 'length == 0'

echo; log "── Network: who may reach what"
svc_ip() { kubectl -n "${OBS_NS}" get svc "$1" -o jsonpath='{.spec.clusterIP}'; }
LOKI_IP="$(svc_ip loki)"; MIMIR_IP="$(svc_ip mimir)"; TEMPO_IP="$(svc_ip tempo)"; PYRO_IP="$(svc_ip pyroscope)"
GW_IP="$(svc_ip obs-gateway)"; OTLP_A="$(svc_ip otlp-tenant-a)"; OTLP_B="$(svc_ip otlp-tenant-b)"; OTLP_C="$(svc_ip otlp-tenant-c)"
# By IP on purpose: tenant DNS would already hide these names; we want to
# prove the packets themselves are dropped.
tcp() { in_tenant "$1" "nc -z -w 3 $2 $3"; }
check "tenant-a -> its own trace receiver"                  ok   tcp tenant-a "$OTLP_A" 4317
check "tenant-c -> its own trace receiver"                  ok   tcp tenant-c "$OTLP_C" 4317
check "tenant-a -> tenant-b's trace receiver"               fail tcp tenant-a "$OTLP_B" 4317
check "tenant-a -> tenant-c's trace receiver"               fail tcp tenant-a "$OTLP_C" 4317
check "tenant-c -> tenant-a's trace receiver"               fail tcp tenant-c "$OTLP_A" 4317
check "tenant-b -> tenant-c's trace receiver"               fail tcp tenant-b "$OTLP_C" 4317
check "tenant-a -> Tempo directly"                          fail tcp tenant-a "$TEMPO_IP" 4317
check "tenant-a -> Mimir"                                   fail tcp tenant-a "$MIMIR_IP" 8080
check "tenant-a -> Loki"                                    fail tcp tenant-a "$LOKI_IP" 3100
check "tenant-a -> Pyroscope"                               fail tcp tenant-a "$PYRO_IP" 4040
check "tenant-a -> the read gateway"                        fail tcp tenant-a "$GW_IP" 8080
check "tenant-c -> the read gateway"                        fail tcp tenant-c "$GW_IP" 8080

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
check "pod in 'default' -> Mimir (the attack)"              fail probe "nc -z -w 3 ${MIMIR_IP} 8080"
check "pod in 'default' -> Tempo"                           fail probe "nc -z -w 3 ${TEMPO_IP} 3200"
check "pod in 'default' -> Loki"                            fail probe "nc -z -w 3 ${LOKI_IP} 3100"
check "pod in 'default' -> Pyroscope"                       fail probe "nc -z -w 3 ${PYRO_IP} 4040"
check "pod in 'default' -> a trace receiver"                fail probe "nc -z -w 3 ${OTLP_A} 4317"
check "pod in 'default' -> the read gateway"                fail probe "nc -z -w 3 ${GW_IP} 8080"

# A pod wearing Alloy's label gets exactly Alloy's rights: push, but no reads.
run_probe "${OBS_NS}" st-l7-probe --labels=app.kubernetes.io/name=alloy
code() { kubectl -n "${OBS_NS}" exec st-l7-probe -- curl -s -m 5 -o /dev/null -w '%{http_code}' "$@" || true; }
is() { [[ "$1" == "$2" ]]; }
not() { [[ "$1" != "$2" ]]; }
check "Alloy identity: Mimir push passes the L7 rule"       ok   not 403 "$(code -X POST -H 'X-Scope-OrgID: platform' -d x "http://${MIMIR_IP}:8080/api/v1/push")"
check "Alloy identity: Mimir query -> 403"                  ok   is 403 "$(code -H 'X-Scope-OrgID: tenant-b' "http://${MIMIR_IP}:8080/prometheus/api/v1/labels")"
check "Alloy identity: Loki query -> 403"                   ok   is 403 "$(code -H 'X-Scope-OrgID: tenant-b' "http://${LOKI_IP}:3100/loki/api/v1/labels")"
check "Alloy identity: Pyroscope query -> 403"              ok   is 403 "$(code -X POST -H 'X-Scope-OrgID: tenant-b' -H 'Content-Type: application/json' -d '{}' "http://${PYRO_IP}:4040/querier.v1.QuerierService/ProfileTypes")"

summary

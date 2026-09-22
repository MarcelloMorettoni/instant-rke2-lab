#!/usr/bin/env bash
# Step 09b: orgs, users and data sources, through Grafana's HTTP API.
#
#   Org "Tenant A"  alice (Editor)   sees tenant-a and tenant-c   (gateway view /tenant-a/)
#   Org "Tenant B"  bob   (Editor)   sees tenant-b                (/tenant-b/)
#   Org "Tenant C"  carol (Editor)   sees tenant-c                (/tenant-c/)
#   Org "Platform"  ops   (Editor)   sees everything              (/platform/)
#   Main Org        nobody, and no data sources
#
# Every org gets Loki, Mimir and Tempo, each covering all the tenants the org
# may see, plus one Pyroscope data source per tenant (Pyroscope can't query
# several tenants at once). They all call the read gateway under the org's
# view, with the org's key; the gateway decides the tenants (step 07). The
# data sources of an org are linked to each other (trace -> logs, trace ->
# metrics, trace -> profile, log line -> trace, metric exemplar -> trace),
# and only ever to data sources of the SAME org.
#
# Every login, admin included, uses ST_PASSWORD (default: test-tenant).
#
# Tenant users are Editors (dashboards, Explore), NEVER org Admins. An org
# Admin can create data sources, including one pointed at another tenant.
#
# Idempotent. Re-run any time: it re-syncs passwords and roles too.
# Outside the cluster (or against another Grafana), set GRAFANA_URL to skip the
# port-forward, and GRAFANA_ADMIN_PASSWORD if admin's password isn't ST_PASSWORD.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
command -v jq >/dev/null || die "jq is required"
ensure_credentials

GATEWAY="${GATEWAY:-http://obs-gateway.${OBS_NS}.svc.cluster.local:8080}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"

if [[ -z "${GRAFANA_URL:-}" ]]; then
  require_cluster
  kubectl -n "${OBS_NS}" port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
  GRAFANA_URL="http://127.0.0.1:3000"
fi
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-${ST_PASSWORD}}"

for _ in $(seq 1 30); do
  curl -sf "${GRAFANA_URL}/api/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "${GRAFANA_URL}/api/health" >/dev/null || die "Grafana not reachable at ${GRAFANA_URL}"

# api METHOD PATH [JSON] [ORG_ID]: prints the body, fails on HTTP >= 400.
api() {
  local method=$1 path=$2 data=${3:-} org=${4:-} out code
  local args=(-sS -X "${method}" -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"
              -H 'Content-Type: application/json' -w $'\n%{http_code}')
  [[ -n "${org}" ]]  && args+=(-H "X-Grafana-Org-Id: ${org}")
  [[ -n "${data}" ]] && args+=(-d "${data}")
  out="$(curl "${args[@]}" "${GRAFANA_URL}${path}")"
  code="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  [[ "${code}" -lt 400 ]]
}

ensure_org() {
  local name=$1 id
  id="$(api GET "/api/orgs/name/$(jq -rn --arg n "${name}" '$n|@uri')" 2>/dev/null \
        | jq -r '.id // empty' || true)"
  if [[ -z "${id}" ]]; then
    id="$(api POST /api/orgs "$(jq -n --arg n "${name}" '{name: $n}')" | jq -r '.orgId')"
  fi
  echo "${id}"
}

ensure_user() {
  local login=$1 password=$2 org=$3 role=$4 uid
  uid="$(api GET "/api/users/lookup?loginOrEmail=${login}" 2>/dev/null | jq -r '.id // empty' || true)"
  if [[ -z "${uid}" ]]; then
    uid="$(api POST /api/admin/users "$(jq -n --arg l "${login}" --arg p "${password}" --argjson o "${org}" \
           '{name: $l, login: $l, email: ($l + "@lab.local"), password: $p, OrgId: $o}')" | jq -r '.id')"
  else
    api PUT "/api/admin/users/${uid}/password" "$(jq -n --arg p "${password}" '{password: $p}')" >/dev/null
  fi
  # Member of the tenant's org with exactly this role (add, or fix the role).
  api POST "/api/orgs/${org}/users" "$(jq -n --arg l "${login}" --arg r "${role}" \
      '{loginOrEmail: $l, role: $r}')" >/dev/null 2>&1 \
    || api PATCH "/api/orgs/${org}/users/${uid}" "$(jq -n --arg r "${role}" '{role: $r}')" >/dev/null
  # Land in that org by default, and drop out of Main Org.
  api POST "/api/users/${uid}/using/${org}" >/dev/null
  api DELETE "/api/orgs/1/users/${uid}" >/dev/null 2>&1 || true
}

put_datasource() {  # put_datasource <org id> <json body>: create or update by uid
  local org=$1 body=$2 uid
  uid="$(jq -r .uid <<<"${body}")"
  if api GET "/api/datasources/uid/${uid}" "" "${org}" >/dev/null 2>&1; then
    api PUT "/api/datasources/uid/${uid}" "${body}" "${org}" >/dev/null
  else
    api POST /api/datasources "${body}" "${org}" >/dev/null
  fi
}

# ensure_datasources <org id> <view> <gateway key> <pyroscope tenant>...
# The first Pyroscope tenant is the org's own: its data source is "Pyroscope",
# and traces link to it. The others are named after their tenant.
ensure_datasources() {
  local org=$1 v=$2 key=$3 own=$4 base common t name uid
  shift 3
  base="${GATEWAY}/${v}"
  # The key goes in a custom header, stored in secureJsonData: encrypted, and
  # never shown to the org's users.
  common="$(jq -n --arg k "${key}" \
    '{access: "proxy", basicAuth: false,
      jsonData: {httpHeaderName1: "X-Api-Key"}, secureJsonData: {httpHeaderValue1: $k}}')"

  put_datasource "${org}" "$(jq -n --argjson c "${common}" --arg v "${v}" --arg url "${base}" '$c * {
    name: "Loki", uid: ("loki-" + $v), type: "loki", url: $url, isDefault: true,
    jsonData: {derivedFields: [{
      name: "TraceID", matcherRegex: "\"trace_id\":\"(\\w+)\"",
      datasourceUid: ("tempo-" + $v), url: "${__value.raw}", urlDisplayLabel: "View trace"}]}}')"

  put_datasource "${org}" "$(jq -n --argjson c "${common}" --arg v "${v}" --arg url "${base}/prometheus" '$c * {
    name: "Mimir", uid: ("mimir-" + $v), type: "prometheus", url: $url,
    jsonData: {prometheusType: "Mimir", httpMethod: "POST",
               exemplarTraceIdDestinations: [{name: "trace_id", datasourceUid: ("tempo-" + $v)}]}}')"

  for t in "$@"; do
    if [[ "${t}" == "${own}" ]]; then name="Pyroscope"; uid="pyroscope-${v}"
    else name="Pyroscope (${t})"; uid="pyroscope-${v}-${t}"; fi
    put_datasource "${org}" "$(jq -n --argjson c "${common}" --arg n "${name}" --arg u "${uid}" \
      --arg url "${base}/pyroscope/${t}" '$c * {
      name: $n, uid: $u, type: "grafana-pyroscope-datasource", url: $url}')"
  done

  put_datasource "${org}" "$(jq -n --argjson c "${common}" --arg v "${v}" --arg url "${base}" '$c * {
    name: "Tempo", uid: ("tempo-" + $v), type: "tempo", url: $url,
    jsonData: {
      tracesToLogsV2: {datasourceUid: ("loki-" + $v), filterByTraceID: true,
                       spanStartTimeShift: "-5m", spanEndTimeShift: "5m",
                       tags: [{key: "service.name", value: "container"}]},
      tracesToMetrics: {datasourceUid: ("mimir-" + $v)},
      tracesToProfiles: {datasourceUid: ("pyroscope-" + $v),
                         profileTypeId: "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
                         tags: [{key: "service.name", value: "service_name"}]},
      serviceMap: {datasourceUid: ("mimir-" + $v)},
      nodeGraph: {enabled: true},
      streamingEnabled: {search: false, metrics: false}}}')"
}

# org name | view | grafana user | Pyroscope tenants, the org's own first
while IFS='|' read -r org_name view g_user pyro_tenants; do
  key_var="OBS_KEY_$(tr 'a-z-' 'A-Z_' <<<"${view}")"
  org_id="$(ensure_org "${org_name}")"
  # shellcheck disable=SC2086  # the tenant list splits on purpose
  ensure_datasources "${org_id}" "${view}" "${!key_var}" ${pyro_tenants}
  ensure_user "${g_user}" "${ST_PASSWORD}" "${org_id}" "Editor"
  ok "Org '${org_name}' (id ${org_id}): user ${g_user}; gateway view /${view}/; Pyroscope: ${pyro_tenants}"
done <<EOF
Tenant A|tenant-a|alice|tenant-a tenant-c
Tenant B|tenant-b|bob|tenant-b
Tenant C|tenant-c|carol|tenant-c
Platform|platform|ops|platform tenant-a tenant-b tenant-c
EOF

# Main Org must stay empty: it's where Grafana drops brand-new users.
MAIN_DS="$(api GET /api/datasources "" 1 | jq 'length')"
[[ "${MAIN_DS}" == "0" ]] || warn "Main Org has ${MAIN_DS} data source(s). New users would see them."

echo
ok "Grafana is set up. To log in:"
echo "    kubectl -n ${OBS_NS} port-forward svc/grafana 3000:80    # then http://localhost:3000"
echo "    alice / ${ST_PASSWORD}    Tenant A: tenant-a and tenant-c"
echo "    bob   / ${ST_PASSWORD}    Tenant B: tenant-b"
echo "    carol / ${ST_PASSWORD}    Tenant C: tenant-c"
echo "    ops   / ${ST_PASSWORD}    Platform: everything"

#!/usr/bin/env bash
# Step 09b: orgs, users and data sources, through Grafana's HTTP API.
#
#   Org "Tenant A"  alice (Editor)  data source "Loki" -> gateway as user tenant-a
#   Org "Tenant B"  bob   (Editor)  data source "Loki" -> gateway as user tenant-b
#   Org "Platform"  ops   (Editor)  data source "Loki" -> gateway as user platform
#   Main Org        nobody, and no data sources
#
# Tenant users are Editors (dashboards, Explore), NEVER org Admins. An org
# Admin can create data sources, including one pointed at another tenant.
#
# Idempotent. Re-run any time: it re-syncs passwords and roles too.
# Outside the cluster (or against another Grafana), set GRAFANA_URL and
# GRAFANA_ADMIN_PASSWORD to skip the port-forward and the Secret lookup.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
command -v jq >/dev/null || die "jq is required"
ensure_credentials

GATEWAY_URL="${GATEWAY_URL:-http://loki-gateway.${OBS_NS}.svc.cluster.local:8080}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"

if [[ -z "${GRAFANA_URL:-}" ]]; then
  require_cluster
  kubectl -n "${OBS_NS}" port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
  GRAFANA_URL="http://127.0.0.1:3000"
fi
if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  GRAFANA_ADMIN_PASSWORD="$(kubectl -n "${OBS_NS}" get secret grafana \
                            -o jsonpath='{.data.admin-password}' | base64 -d)"
fi

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

ensure_datasource() {
  local org=$1 uid=$2 gw_user=$3 gw_password=$4 body
  body="$(jq -n --arg uid "${uid}" --arg url "${GATEWAY_URL}" --arg u "${gw_user}" --arg p "${gw_password}" '{
      name: "Loki", uid: $uid, type: "loki", access: "proxy", url: $url, isDefault: true,
      basicAuth: true, basicAuthUser: $u, secureJsonData: {basicAuthPassword: $p}
    }')"
  if api GET "/api/datasources/uid/${uid}" "" "${org}" >/dev/null 2>&1; then
    api PUT "/api/datasources/uid/${uid}" "${body}" "${org}" >/dev/null
  else
    api POST /api/datasources "${body}" "${org}" >/dev/null
  fi
}

# org name | Loki data source uid | gateway user | gateway password | grafana user | password
while IFS='|' read -r org_name ds_uid gw_user gw_pw g_user g_pw; do
  org_id="$(ensure_org "${org_name}")"
  ensure_datasource "${org_id}" "${ds_uid}" "${gw_user}" "${gw_pw}"
  ensure_user "${g_user}" "${g_pw}" "${org_id}" "Editor"
  ok "Org '${org_name}' (id ${org_id}): user ${g_user}, data source ${ds_uid} -> gateway as ${gw_user}"
done <<EOF
Tenant A|loki-tenant-a|tenant-a|${LOKI_PW_TENANT_A}|alice|${GRAFANA_PW_ALICE}
Tenant B|loki-tenant-b|tenant-b|${LOKI_PW_TENANT_B}|bob|${GRAFANA_PW_BOB}
Platform|loki-platform|platform|${LOKI_PW_PLATFORM}|ops|${GRAFANA_PW_OPS}
EOF

# Main Org must stay empty: it's where Grafana drops brand-new users.
MAIN_DS="$(api GET /api/datasources "" 1 | jq 'length')"
[[ "${MAIN_DS}" == "0" ]] || warn "Main Org has ${MAIN_DS} data source(s). New users would see them."

echo
ok "Grafana is set up. To log in:"
echo "    kubectl -n ${OBS_NS} port-forward svc/grafana 3000:80    # then http://localhost:3000"
echo "    alice / ${GRAFANA_PW_ALICE}    (Tenant A)"
echo "    bob   / ${GRAFANA_PW_BOB}    (Tenant B)"
echo "    ops   / ${GRAFANA_PW_OPS}    (Platform)"
echo "    (passwords are also in ${CREDS_FILE})"

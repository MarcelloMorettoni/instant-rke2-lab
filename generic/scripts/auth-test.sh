#!/usr/bin/env bash
# Sign-in test against a REAL Grafana (the chart's image), in Docker. No cluster.
#
#   scripts/auth-test.sh
#
# For each auth.provider, renders the chart, starts Grafana with the exact
# GF_AUTH_* settings (ConfigMap grafana-auth) and accounts (Secrets
# grafana-admin, grafana-local-users), SQLite instead of PostgreSQL, and runs
# the chart's grafana-sync code against it:
#   every mode  local admin: change-me-now, server admin, platform org, form at
#               /login?disableAutoLogin=true; grafana-sync uses its OWN account
#   entra       /login/azuread → the tenant's authorize endpoint, client ID, PKCE
#   keycloak    /login/generic_oauth → the realm's auth endpoint, client, PKCE, scopes
#   disabled    alice/bob/carol: exactly their org; passwords changed in Grafana
#               survive the next grafana-sync run; grafana-sync keeps working
#               after the admin changed its password
# Results are checked inside eval'd assertions, which shellcheck can't follow.
# shellcheck disable=SC2034
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker helm python3 curl
cd "${GEN_DIR}"
python3 scripts/render-tenants.py >/dev/null
IMAGE="grafana/grafana:13.2.2"
W="$(mktemp -d)"; NAME="auth-test-$$"
cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; rm -rf "${W}"; }
trap cleanup EXIT
PASS=0; FAIL=0
t() { if eval "$2"; then ok "PASS  $1"; PASS=$((PASS+1)); else err "FAIL  $1"; FAIL=$((FAIL+1)); fi; }

render() {  # render <provider> [--set ...]: env file, sync config and account secrets into ${W}
  local p=$1; shift
  rm -rf "${W:?}"/*
  helm template log-platform charts/log-platform -n loki -f environments/example/values.yaml \
    -f environments/example/generated-images.yaml -f rendered/values-tenants.yaml \
    --set auth.provider="${p}" "$@" > "${W}/chart.yaml"
  python3 - "${W}" <<'PY'
import sys, yaml, base64, pathlib
w = pathlib.Path(sys.argv[1])
for d in yaml.safe_load_all((w / "chart.yaml").read_text()):
    if not d:
        continue
    name = d["metadata"]["name"]
    if d["kind"] == "ConfigMap" and name == "grafana-auth":
        (w / "env").write_text("".join(f"{k}={v}\n" for k, v in d["data"].items()))
    if d["kind"] == "ConfigMap" and name == "grafana-sync":
        (w / "config").mkdir(exist_ok=True)
        for k, v in d["data"].items():
            (w / "config" / k).write_text(v)
    if d["kind"] == "Secret" and name in ("grafana-local-users", "grafana-admin"):
        (w / name).mkdir(exist_ok=True)
        for k, v in (d.get("data") or {}).items():
            (w / name / k).write_text(base64.b64decode(v).decode())
PY
  mkdir -p "${W}/keys"
  for v in $(python3 -c "import json,sys; print(' '.join(o['view'] for o in json.load(open(sys.argv[1]))))" "${W}/config/orgs.json"); do
    printf 'key-%s' "${v}" > "${W}/keys/obs-key-${v}"
  done
  sed -e "s#/config/#${W}/config/#g; s#f\"/keys/#f\"${W}/keys/#; s#f\"/local/#f\"${W}/grafana-local-users/#; s#\"/breakglass/password\"#\"${W}/none\"#" \
    charts/log-platform/files/grafana-sync.py > "${W}/sync.py"
}

start() {  # Grafana with the chart's settings; its built-in admin = the automation account
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${NAME}" -p 127.0.0.1::3000 --env-file "${W}/env" \
    -e GF_SECURITY_ADMIN_USER="$(cat "${W}/grafana-admin/admin-user")" \
    -e GF_SECURITY_ADMIN_PASSWORD="$(cat "${W}/grafana-admin/admin-password")" \
    -e GF_SERVER_ROOT_URL=https://grafana.obs-test.bank.internal \
    -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_USERS_AUTO_ASSIGN_ORG=true \
    -e GF_USERS_AUTO_ASSIGN_ORG_ID=1 -e GF_USERS_ALLOW_ORG_CREATE=false "${IMAGE}" >/dev/null
  G="http://127.0.0.1:$(docker port "${NAME}" 3000/tcp | head -1 | cut -d: -f2)"
  for _ in $(seq 1 60); do curl -sf "${G}/api/health" >/dev/null && return 0; sleep 1; done
  docker logs "${NAME}" | tail -20; die "Grafana did not start"
}
sync() {  # grafana-sync exactly as the CronJob runs it
  GRAFANA_URL="${G}" GF_ADMIN_USER="$(cat "${W}/grafana-admin/admin-user")" \
    GF_ADMIN_PASSWORD="$(cat "${W}/grafana-admin/admin-password")" python3 "${W}/sync.py" > "${W}/sync.log" 2>&1
}
# Settings as the login page gives them to the browser (window.grafanaBootData,
# a JS object; the two fields used here are plain JSON inside it).
setting() {
  curl -sf "${G}/login?disableAutoLogin=true" | python3 -c "
import json, re, sys
page = sys.stdin.read()
i = page.index('\"oauth\":') + len('\"oauth\":')
d = {'disableLoginForm': re.search(r'\"disableLoginForm\":(true|false)', page).group(1) == 'true',
     'oauth': json.JSONDecoder().raw_decode(page[i:])[0]}
print($1)"
}
redirect() { curl -s -o /dev/null -w '%{redirect_url}' "${G}$1"; }
orgs_of() {  # orgs_of <login> <password> → "org:role org:role"
  curl -sf -u "$1:$2" "${G}/api/user/orgs" \
    | python3 -c "import json,sys; print(' '.join(sorted(o['name']+':'+o['role'] for o in json.load(sys.stdin))))"
}
is_server_admin() { curl -sf -u "$1:$2" "${G}/api/user" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin)['isGrafanaAdmin'] else 1)"; }
login_ok() { [[ "$(curl -s -o /dev/null -w '%{http_code}' -u "$1:$2" "${G}/api/user")" == 200 ]]; }

admin_checks() {  # admin_checks <mode>
  t "$1: grafana-sync (automation account) succeeds" 'sync && ! grep -qi "failed" "${W}/sync.log"'
  t "$1: password form available at /login?disableAutoLogin=true" '[[ "$(setting "d[\"disableLoginForm\"]")" == False ]]'
  t "$1: admin / change-me-now signs in"       'login_ok admin change-me-now'
  t "$1: admin is Grafana server admin"        'is_server_admin admin change-me-now'
  t "$1: admin is Admin of the platform org"   'grep -q "platform:Admin" <<<"$(orgs_of admin change-me-now)"'
  t "$1: no password or key in the sync output" '! grep -qE "key-|change-me-now|$(cat "${W}/grafana-admin/admin-password")" "${W}/sync.log"'
}

log "entra"
render entra; start
t "entra: Grafana starts with the chart's settings, no config errors" '! docker logs "${NAME}" 2>&1 | grep -qiE "level=error.*(org_mapping|azuread|oauth)"'
admin_checks entra
t "entra: Entra ID offered as a provider"      '[[ "$(setting "\"azuread\" in d[\"oauth\"]")" == True ]]'
R="$(redirect /login/azuread)"
t "entra: redirects to the tenant's authorize endpoint" 'grep -q "^https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/oauth2/v2.0/authorize" <<<"${R}"'
t "entra: with the client ID and PKCE"         'grep -q "client_id=00000000-0000-0000-0000-000000000000" <<<"${R}" && grep -q "code_challenge=" <<<"${R}"'

log "keycloak"
render keycloak --set auth.keycloak.url=https://sso.bank.internal --set auth.keycloak.realm=bank; start
t "keycloak: Grafana starts, no config errors" '! docker logs "${NAME}" 2>&1 | grep -qiE "level=error.*(org_mapping|generic_oauth|oauth)"'
admin_checks keycloak
t "keycloak: generic OAuth offered, named Bank SSO" '[[ "$(setting "d[\"oauth\"][\"generic_oauth\"][\"name\"]")" == "Bank SSO" ]]'
R="$(redirect /login/generic_oauth)"
t "keycloak: redirects to the realm's auth endpoint" 'grep -q "^https://sso.bank.internal/realms/bank/protocol/openid-connect/auth" <<<"${R}"'
t "keycloak: with client grafana, PKCE, the scopes" 'grep -q "client_id=grafana" <<<"${R}" && grep -q "code_challenge=" <<<"${R}" && grep -q "scope=openid+profile+email" <<<"${R}"'

log "disabled (mock)"
render disabled; start
admin_checks mock
t "mock: no SSO provider"                      '[[ "$(setting "len(d[\"oauth\"])")" == 0 ]]'
t "mock: alice / change-me-now → payments only, Editor" '[[ "$(orgs_of alice change-me-now)" == "payments:Editor" ]]'
t "mock: bob → cards only, Editor"              '[[ "$(orgs_of bob change-me-now)" == "cards:Editor" ]]'
t "mock: carol → lending only, Editor"          '[[ "$(orgs_of carol change-me-now)" == "lending:Editor" ]]'
CARDS_ORG="$(curl -sf -u "admin:change-me-now" "${G}/api/orgs/name/cards" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
t "mock: alice can't read cards' data source"   '[[ "$(curl -s -o /dev/null -w "%{http_code}" -u alice:change-me-now -H "X-Grafana-Org-Id: ${CARDS_ORG}" "${G}/api/datasources/uid/loki-cards")" =~ ^40[13]$ ]]'
# (admin is only in the platform org, whose data source reads every tenant;
# the org's own data source is checked as the automation account.)
AUTO="$(cat "${W}/grafana-admin/admin-user"):$(cat "${W}/grafana-admin/admin-password")"
t "mock: each org's Loki data source → its view" '[[ "$(curl -sf -u "${AUTO}" -H "X-Grafana-Org-Id: ${CARDS_ORG}" "${G}/api/datasources/uid/loki-cards" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"url\"])")" == http://obs-gateway.loki.svc.cluster.local:8080/cards ]]'
t "mock: wrong password refused"                '[[ "$(curl -s -o /dev/null -w "%{http_code}" -u alice:wrong "${G}/api/user")" == 401 ]]'
# People change their passwords; the next grafana-sync run must not undo it.
curl -sf -o /dev/null -u alice:change-me-now -X PUT -H 'Content-Type: application/json' "${G}/api/user/password" \
  -d '{"oldPassword":"change-me-now","newPassword":"alice-new-pw-123","confirmNew":"alice-new-pw-123"}'
curl -sf -o /dev/null -u admin:change-me-now -X PUT -H 'Content-Type: application/json' "${G}/api/user/password" \
  -d '{"oldPassword":"change-me-now","newPassword":"admin-new-pw-123","confirmNew":"admin-new-pw-123"}'
t "mock: grafana-sync still works after admin changed its password" 'sync && ! grep -qi "failed" "${W}/sync.log"'
t "mock: admin's new password survives grafana-sync" 'login_ok admin admin-new-pw-123 && ! login_ok admin change-me-now'
t "mock: alice's new password survives grafana-sync" 'login_ok alice alice-new-pw-123 && ! login_ok alice change-me-now'

echo
if (( FAIL == 0 )); then ok "All ${PASS} sign-in checks passed"; else die "${FAIL} of $((PASS+FAIL)) sign-in checks failed"; fi

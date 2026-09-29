#!/usr/bin/env bash
# Post-install checks against the live cluster: readiness, the read gateway's
# key/view/header rules, and network isolation. Read-only: it never writes
# logs as a tenant. Run after every install and every tenants.yaml change.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl jq curl python3
load_env "${1:-}"
require_context
REG="$(value_of global.imageRegistry)"
PASS=0; FAIL=0
check() {   # check "<description>" ok|fail <command...>
  local d=$1 want=$2 got; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=fail; fi
  if [[ "${got}" == "${want}" ]]; then ok "PASS  ${d}"; PASS=$((PASS+1)); else err "FAIL  ${d} (expected ${want})"; FAIL=$((FAIL+1)); fi
}

log "Loki components ready"
for c in distributor query-frontend query-scheduler querier index-gateway compactor; do
  check "${c} has ready pods" ok \
    bash -c "kubectl -n loki get pods -l app.kubernetes.io/component=${c} -o json | jq -e '[.items[].status.conditions[]? | select(.type==\"Ready\" and .status==\"True\")] | length > 0'"
done
for z in a b c; do
  check "ingester zone ${z} fully ready" ok \
    bash -c "kubectl -n loki get sts loki-ingester-zone-${z} -o json | jq -e '.status.readyReplicas == .spec.replicas'"
done
check "OTel agent ready on every node" ok \
  bash -c "kubectl -n otel-agent get ds otel-agent-agent -o json | jq -e '.status.numberReady == .status.desiredNumberScheduled'"
check "OTel gateway fully ready" ok \
  bash -c "kubectl -n otel get sts otel-gateway -o json | jq -e '.status.readyReplicas == .spec.replicas'"

log "Read gateway (through a port-forward)"
kubectl -n loki port-forward svc/obs-gateway 18080:8080 >/dev/null 2>&1 &
PF=$!; trap 'kill ${PF} 2>/dev/null || true' EXIT; sleep 3
KEYS="$(kubectl -n grafana get secret obs-gateway-keys -o json | jq '.data | map_values(@base64d)')"
view="$(jq -r '.[1].view // .[0].view' "${GEN_DIR}/rendered/grafana-orgs.json")"
other="$(jq -r --arg v "${view}" '[.[] | select(.view != $v)][0].view' "${GEN_DIR}/rendered/grafana-orgs.json")"
key="$(jq -r --arg k "obs-key-${view}" '.[$k]' <<<"${KEYS}")"
G=http://127.0.0.1:18080
check "view ${view} with its key: 200" ok curl -sf -H "X-Api-Key: ${key}" "${G}/${view}/loki/api/v1/labels"
check "view ${view} without a key: refused" fail curl -sf "${G}/${view}/loki/api/v1/labels"
check "view ${other} with ${view}'s key: refused" fail curl -sf -H "X-Api-Key: ${key}" "${G}/${other}/loki/api/v1/labels"
check "push through the gateway: refused" fail curl -sf -X POST -H "X-Api-Key: ${key}" "${G}/${view}/loki/api/v1/push"
check "delete through the gateway: refused" fail curl -sf -X POST -H "X-Api-Key: ${key}" "${G}/${view}/loki/api/v1/delete?query=%7Ba%3D%22b%22%7D"

kubectl -n grafana port-forward svc/grafana 13000:80 >/dev/null 2>&1 &
PF2=$!; sleep 3
PROVIDER="$(kubectl -n grafana get configmap grafana-auth -o jsonpath='{.metadata.labels.obs\.platform/auth-provider}')"
ADMIN="$(kubectl -n grafana get configmap grafana-sync -o jsonpath='{.data.users\.json}' | jq -r .admin)"
log "Local admin ${ADMIN} (sign-in provider: ${PROVIDER})"
check "admin ${ADMIN} exists and is a Grafana server admin" ok bash -c "
  pw=\$(kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
  curl -sf -u grafana-sync:\${pw} http://127.0.0.1:13000/api/users/lookup?loginOrEmail=${ADMIN} | jq -e .isGrafanaAdmin"
if curl -sf -o /dev/null -u "${ADMIN}:change-me-now" http://127.0.0.1:13000/api/user; then
  warn "WARNING  ${ADMIN} still has the DEFAULT password change-me-now: change it now"
fi
if [[ "${PROVIDER}" == disabled ]]; then
  log "Mock sign-in: each mock user sees exactly its org"
  for login in $(kubectl -n grafana get configmap grafana-sync -o jsonpath='{.data.users\.json}' | jq -r '.users[].login'); do
    pw="$(kubectl -n grafana get secret grafana-local-users -o jsonpath="{.data.${login}}" | base64 -d)"
    n="$(curl -sf -u "${login}:${pw}" http://127.0.0.1:13000/api/user/orgs | jq length || echo 0)"
    check "mock user ${login} is in exactly one org (if its password is unchanged)" ok test "${n}" = 1
  done
fi
kill "${PF2}" 2>/dev/null || true

log "Network isolation: a pod in the default namespace (no tenant rights)"
# SMOKE_IMAGE: any image with curl (default: curlimages/curl through the registry).
probe() {  # probe <url>: run curl from a short-lived pod in `default`
  kubectl -n default run "np-probe-$RANDOM" --rm -i --restart=Never --quiet \
    --image="${SMOKE_IMAGE:-${REG:+${REG%/}/}curlimages/curl:8.16.0}" --command -- \
    curl -s -m 5 -o /dev/null -w '%{http_code}' "$1" | grep -qE '^[1-5][0-9][0-9]$'
}
check "default ns → distributor push: blocked" fail probe http://loki-distributor.loki.svc.cluster.local:3100/ready
check "default ns → query-frontend: blocked"   fail probe http://loki-query-frontend.loki.svc.cluster.local:3100/ready
check "default ns → read gateway: blocked"     fail probe http://obs-gateway.loki.svc.cluster.local:8080/
check "default ns → OTel gateway: blocked"     fail probe http://otel-gateway.otel.svc.cluster.local:4317/
check "default ns → OTel agent OTLP: allowed"  ok   probe http://otel-agent.otel-agent.svc.cluster.local:4318/v1/logs

echo; if (( FAIL == 0 )); then ok "All ${PASS} checks passed"; else die "${FAIL} of $((PASS+FAIL)) checks failed"; fi

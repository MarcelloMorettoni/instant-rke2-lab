#!/usr/bin/env bash
# Install or upgrade the whole log platform on one cluster, from its
# environment folder. Idempotent: re-run after any change.
#
#   scripts/install.sh <env>          all steps
#   scripts/install.sh <env> 30       resume from step 30
#
# Prerequisites: Terraform applied (infra/terraform); environments/<env>/
# filled in (values.yaml, cluster.env; terraform.yaml from `terraform output`).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl helm python3 jq
load_env "${1:-}"
FROM="${2:-00}"
require_context
step() { [[ "$1" < "${FROM}" ]] && return 1; log "── step $1: $2"; }
cd "${GEN_DIR}"

if step 00 "render tenants and images"; then
  python3 scripts/render-tenants.py
  python3 scripts/render-images.py "${ENV_NAME}"
fi

if step 10 "operators: CRDs, kgateway, Strimzi, Keycloak operator, External Secrets; namespaces loki, kafka, keycloak"; then
  helm upgrade --install log-platform-operators charts/log-platform-operators \
    -n platform-operators --create-namespace "${ENV_VALUES[@]}" --wait --timeout 10m
fi

if step 20 "read-gateway keys in Key Vault (one per view; created only if missing)"; then
  if [[ "$(value_of keyVault.enabled)" == "false" ]]; then
    log "keyVault.enabled is false: the chart generates the view keys (step 30)"
  else
    scripts/tenant-keys.sh "${ENV_NAME}"
  fi
fi

if step 25 "PostgreSQL users for Grafana (and Keycloak), when it is Percona in the cluster"; then
  if [[ "$(value_of postgres.provider)" == "percona" ]]; then
    ns="$(value_of postgres.percona.namespace)"; ns="${ns:-postgres}"
    cl="$(value_of postgres.percona.cluster)"; cl="${cl:-obs-pg}"
    for u in grafana $( [[ "$(value_of keycloak.install)" == "true" ]] && echo keycloak ); do
      kubectl -n "${ns}" get secret "${cl}-pguser-${u}" >/dev/null 2>&1 \
        || die "no Secret ${ns}/${cl}-pguser-${u}: create the PerconaPGCluster first (examples/percona-postgresql.yaml)"
    done
    ok "Percona user Secrets found in ${ns}; step 30 copies them"
  fi
fi

if step 30 "log platform (Kafka, Loki, OTel agent + gateway, Grafana, Keycloak, policies, views)"; then
  before="$(kubectl -n grafana get configmap grafana-auth -o jsonpath='{.data}' 2>/dev/null || true)"
  helm upgrade --install log-platform charts/log-platform -n loki \
    "${PLATFORM_VALUES[@]}" --wait --timeout 20m
  after="$(kubectl -n grafana get configmap grafana-auth -o jsonpath='{.data}')"
  if [[ -n "${before}" && "${before}" != "${after}" ]]; then
    log "sign-in settings (provider or group → org mapping) changed: restarting Grafana"
    kubectl -n grafana rollout restart deploy/grafana
    kubectl -n grafana rollout status deploy/grafana --timeout=5m
  fi
fi

if step 40 "Grafana orgs and data sources (grafana-sync, now instead of at the next schedule)"; then
  job="grafana-sync-$(date +%s)"
  kubectl -n grafana create job --from=cronjob/grafana-sync "${job}" >/dev/null
  kubectl -n grafana wait --for=condition=complete "job/${job}" --timeout=10m \
    || { kubectl -n grafana logs "job/${job}" || true; die "grafana-sync failed"; }
  kubectl -n grafana logs "job/${job}"
fi

if step 50 "smoke test"; then
  scripts/smoke-test.sh "${ENV_NAME}"
fi
ok "Log platform installed on $(kubectl config current-context)"

#!/usr/bin/env bash
# One random read key per read-gateway view, stored ONLY in Azure Key Vault.
#
#   scripts/tenant-keys.sh <env>               create the keys that are missing
#   scripts/tenant-keys.sh <env> --rotate VIEW replace VIEW's key and apply it now
#
# Keys never appear on a command line, in git, or in this script's output.
# External Secrets copies them to the gateway (ns loki) and to grafana-sync
# (ns grafana), which writes each into its org's data source.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need az jq openssl python3
load_env "${1:-}"
KV_URL="$(value_of keyVault.url)"
[[ -n "${KV_URL}" ]] || KV_URL="$(python3 -c "import yaml,sys; print(((yaml.safe_load(open(sys.argv[1])) or {}).get('keyVault') or {}).get('url',''))" "${ENV_DIR}/terraform.yaml" 2>/dev/null || true)"
KV="$(sed -E 's#^https://([^.]+)\..*#\1#' <<<"${KV_URL}")"
[[ -n "${KV}" ]] || die "keyVault.url is not set for ${ENV_NAME}"
ORGS="${GEN_DIR}/rendered/grafana-orgs.json"
[[ -f "${ORGS}" ]] || die "run scripts/render-tenants.py first"

put_random_key() {   # put_random_key <view>
  local tmp; tmp="$(mktemp)"; chmod 600 "${tmp}"
  openssl rand -hex 32 | tr -d '\n' > "${tmp}"
  az keyvault secret set --vault-name "${KV}" --name "obs-key-$1" --file "${tmp}" --encoding utf-8 \
    --content-type "obs read-gateway key" --tags "view=$1" --output none
  rm -f "${tmp}"
}

if [[ "${2:-}" == "--rotate" ]]; then
  view="${3:?usage: tenant-keys.sh <env> --rotate VIEW}"
  jq -e --arg v "${view}" 'any(.[]; .view == $v)' "${ORGS}" >/dev/null || die "unknown view ${view}"
  require_context
  log "Rotating the key of view ${view} in ${KV}"
  put_random_key "${view}"
  stamp="$(date +%s)"
  kubectl -n loki annotate externalsecret "obs-key-${view}" force-sync="${stamp}" --overwrite >/dev/null
  kubectl -n grafana annotate externalsecret obs-gateway-keys force-sync="${stamp}" --overwrite >/dev/null
  sleep 15
  kubectl -n grafana create job --from=cronjob/grafana-sync "grafana-sync-rotate-${stamp}" >/dev/null
  kubectl -n grafana wait --for=condition=complete "job/grafana-sync-rotate-${stamp}" --timeout=5m
  ok "Rotated. Between the gateway and Grafana updates, that org may have seen 401 for a few seconds."
  exit 0
fi

for view in $(jq -r '.[].view' "${ORGS}"); do
  if az keyvault secret show --vault-name "${KV}" --name "obs-key-${view}" --output none 2>/dev/null; then
    log "obs-key-${view}: exists"
  else
    put_random_key "${view}"
    ok "obs-key-${view}: created"
  fi
done

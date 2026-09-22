#!/usr/bin/env bash
# Shared helpers for the soft-tenancy exercises. Source me, don't run me.
# shellcheck disable=SC2034,SC1090

set -euo pipefail

ST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${ST_DIR}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${LAB_ROOT}/.state/kubeconfig}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { printf '%s[soft-tenancy]%s %s\n' "$BLUE"   "$NC" "$*" >&2; }
ok()   { printf '%s[soft-tenancy]%s %s\n' "$GREEN"  "$NC" "$*" >&2; }
warn() { printf '%s[soft-tenancy]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s[soft-tenancy]%s %s\n' "$RED"    "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Pinned so every run renders the same manifests.
LOKI_CHART_VERSION="7.3.0"          # Loki 3.6
ALLOY_CHART_VERSION="1.12.1"        # Alloy 1.19
GRAFANA_CHART_VERSION="13.2.5"      # Grafana 13.2 (chart moved to grafana-community)

OBS_NS="observability"

# Generated secrets live next to the lab's other state: gitignored, mode 600.
CREDS_DIR="${ST_CREDS_DIR:-${LAB_ROOT}/.state/soft-tenancy}"
CREDS_FILE="${CREDS_DIR}/credentials.env"

require_cluster() {
  command -v kubectl >/dev/null || die "kubectl not installed. Run 'make prereqs' in the lab root"
  [[ -f "$KUBECONFIG" ]] || die "kubeconfig not found at $KUBECONFIG. Run 'make all' in the lab root first"
  kubectl get --raw /readyz >/dev/null 2>&1 || die "API server not reachable with $KUBECONFIG"
}

require_helm() {
  command -v helm >/dev/null || die "helm not installed. See https://helm.sh/docs/intro/install/"
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update >/dev/null
  helm repo update grafana grafana-community >/dev/null
}

# RKE2 ships no default StorageClass. Same approach as ../slinky/install.sh.
ensure_default_storageclass() {
  if kubectl get sc 2>/dev/null | grep -q '(default)'; then
    return 0
  fi
  log "No default StorageClass. Installing local-path-provisioner"
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl wait --for=condition=Available --timeout=120s -n local-path-storage deploy/local-path-provisioner
  kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=true --overwrite
}

# One random password per Loki tenant and per Grafana user, created once.
ensure_credentials() {
  if [[ ! -f "$CREDS_FILE" ]]; then
    command -v openssl >/dev/null || die "openssl is needed to generate credentials"
    mkdir -p "$CREDS_DIR" && chmod 700 "$CREDS_DIR"
    (
      umask 077
      for v in LOKI_PW_TENANT_A LOKI_PW_TENANT_B LOKI_PW_PLATFORM \
               GRAFANA_PW_ALICE GRAFANA_PW_BOB GRAFANA_PW_OPS; do
        echo "${v}=$(openssl rand -hex 16)"
      done
    ) > "$CREDS_FILE"
    ok "Generated credentials in ${CREDS_FILE}"
  fi
  source "$CREDS_FILE"
}

###############################################################################
# Tiny test harness for the verify scripts
###############################################################################
PASS=0
FAIL=0

# check "<description>" ok|fail <command...>
#   ok   = the command must succeed
#   fail = the command must fail (connection dropped, request denied, ...)
check() {
  local desc=$1 expect=$2 got
  shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=fail; fi
  if [[ "$got" == "$expect" ]]; then
    ok "PASS  ${desc}"
    PASS=$((PASS + 1))
  else
    err "FAIL  ${desc}  (expected ${expect}, got ${got})"
    FAIL=$((FAIL + 1))
  fi
}

summary() {
  echo
  if (( FAIL == 0 )); then
    ok "All ${PASS} checks passed"
  else
    die "${FAIL} of $((PASS + FAIL)) checks failed"
  fi
}

# Run a shell snippet inside a tenant's client pod.
in_tenant() {
  local ns=$1
  shift
  kubectl -n "$ns" exec deploy/client -c client -- sh -c "$*"
}

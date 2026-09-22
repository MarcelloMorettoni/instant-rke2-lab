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
TEMPO_CHART_VERSION="3.0.0"         # Tempo 3.0 (grafana-community/tempo, monolithic)
PYROSCOPE_CHART_VERSION="2.3.1"     # Pyroscope 2.3
MIMIR_VERSION="3.2.1"               # Mimir 3.2, plain manifest (06-observability-backends/mimir.yaml)
KGATEWAY_VERSION="v2.4.5"           # read gateway + ingress (Gateway API implementation, Envoy-based)
GATEWAY_API_VERSION="v1.6.1"        # standard-channel CRDs kgateway 2.4 is built against

OBS_NS="observability"
GW_NS="kgateway-system"

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

# One password for every Grafana login (alice, bob, carol, ops, admin). A lab
# convenience: override with ST_PASSWORD=... before running any step.
ST_PASSWORD="${ST_PASSWORD:-test-tenant}"

# Read-gateway keys, one per Grafana org (step 07). Generated once and kept in
# the credentials file. They stay random and distinct: each key opens exactly
# one org's view, so equal keys would let one org read another's.
CRED_VARS=(OBS_KEY_TENANT_A OBS_KEY_TENANT_B OBS_KEY_TENANT_C OBS_KEY_PLATFORM)
ensure_credentials() {
  local v added=0
  mkdir -p "$CREDS_DIR" && chmod 700 "$CREDS_DIR"
  [[ -f "$CREDS_FILE" ]] && source "$CREDS_FILE"
  for v in "${CRED_VARS[@]}"; do
    [[ -n "${!v:-}" ]] && continue
    command -v openssl >/dev/null || die "openssl is needed to generate credentials"
    (umask 077; echo "${v}=$(openssl rand -hex 24)" >> "$CREDS_FILE")
    added=1
  done
  (( added )) && ok "Generated gateway keys in ${CREDS_FILE}"
  source "$CREDS_FILE"
  # Grafana logins all use ST_PASSWORD (older credentials files had random ones).
  GRAFANA_PW_ALICE="${ST_PASSWORD}"; GRAFANA_PW_BOB="${ST_PASSWORD}"
  GRAFANA_PW_CAROL="${ST_PASSWORD}"; GRAFANA_PW_OPS="${ST_PASSWORD}"
}

# kgateway serves both gateways in this lab: the read gateway in front of the
# observability backends (step 07) and the tenant ingress (step 12).
# Idempotent: step 12 calls it again and it only re-applies.
install_kgateway() {
  command -v helm >/dev/null || die "helm not installed. See https://helm.sh/docs/intro/install/"
  # Gateway API CRDs. Some distributions (or another ingress, such as a bundled
  # Traefik) install them already. Never overwrite CRDs someone else manages.
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    local have
    have="$(kubectl get crd gateways.gateway.networking.k8s.io \
            -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
    if [[ "${have}" != "${GATEWAY_API_VERSION}" ]]; then
      warn "Gateway API CRDs already present (bundle ${have:-unknown}); leaving them alone."
      warn "kgateway ${KGATEWAY_VERSION} is built against ${GATEWAY_API_VERSION}; upgrade them if routes misbehave."
    fi
  else
    log "Installing Gateway API ${GATEWAY_API_VERSION} CRDs (standard channel)"
    kubectl apply --server-side -f \
      "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  fi

  log "Installing kgateway ${KGATEWAY_VERSION} into ${GW_NS}"
  # stdout only carries the charts' notes (uninstall hints); errors still show.
  helm upgrade --install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
    --version "${KGATEWAY_VERSION}" --namespace "${GW_NS}" --create-namespace --wait >/dev/null
  helm upgrade --install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
    --version "${KGATEWAY_VERSION}" --namespace "${GW_NS}" --wait --timeout 5m >/dev/null

  log "Waiting for the kgateway GatewayClass"
  local _
  for _ in $(seq 1 60); do
    kubectl get gatewayclass kgateway >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl wait --for=condition=Accepted gatewayclass/kgateway --timeout=120s
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

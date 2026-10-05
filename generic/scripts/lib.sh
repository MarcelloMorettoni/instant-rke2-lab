#!/usr/bin/env bash
# Shared helpers for the generic AKS log platform. Source me, don't run me.
# shellcheck disable=SC2034
set -euo pipefail

GEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${GEN_DIR}/.cache"

# Temp files (mktemp, test clusters' configs) stay on this repo's disk, never
# in /tmp: the host's root filesystem is small. Override with GEN_DIR_TMPDIR=...
export TMPDIR="${GEN_DIR_TMPDIR:-${CACHE_DIR}/tmp}"
mkdir -p "${TMPDIR}"

# Pinned. Loki, Grafana and kgateway match ../soft-tenancy/lib.sh; collection
# is OpenTelemetry here (the lab uses Grafana Alloy).
LOKI_CHART_VERSION="7.3.0"          # Loki 3.6.11
OTEL_CHART_VERSION="0.173.1"        # open-telemetry/opentelemetry-collector → collector 0.160.0
GRAFANA_CHART_VERSION="13.2.5"      # Grafana 13.2
KGATEWAY_VERSION="v2.4.5"
GATEWAY_API_VERSION="v1.6.1"
ESO_CHART_VERSION="2.11.0"          # External Secrets Operator
STRIMZI_CHART_VERSION="1.2.0"       # Strimzi Kafka operator → Kafka 4.3.1 (KRaft)
KEYCLOAK_VERSION="26.8.0"           # Keycloak operator + server (CRDs in the operators chart)
PERCONA_PG_VERSION="2.9.0"          # examples/percona-postgresql.yaml (schema check only)
LOKI_IMAGE="grafana/loki:3.6.11"
OTELCOL_IMAGE="otel/opentelemetry-collector-contrib:0.160.0"
PROMTOOL_IMAGE="prom/prometheus:v3.5.0"
KAFKA_IMAGE="apache/kafka:4.3.1"    # pipeline-test; the cluster runs Strimzi's build of the same version
PROM_LABEL_PROXY_IMAGE="quay.io/prometheuscommunity/prom-label-proxy:v0.15.1"   # = metricsStore.proxy.image
CILIUM_CRD_VERSION="v1.17.6"        # schema for templates/networkpolicies-cilium.yaml
PROM_OPERATOR_VERSION="v0.85.0"     # PodMonitor schema (Azure's azmonitoring group mirrors it)

# load_env <env>: environments/<env>/cluster.env (KUBE_CONTEXT) and paths.
load_env() {
  ENV_NAME="${1:?usage: $0 <env>   (a folder in environments/)}"
  ENV_DIR="${GEN_DIR}/environments/${ENV_NAME}"
  [[ -f "${ENV_DIR}/values.yaml" ]] || die "no ${ENV_DIR}/values.yaml (copy environments/azure)"
  # shellcheck disable=SC1091
  [[ -f "${ENV_DIR}/cluster.env" ]] && source "${ENV_DIR}/cluster.env"
  # Values for both charts, in order: environment, Terraform outputs (optional),
  # optional overlays listed in environments/<env>/overlays.txt, generated images.
  ENV_VALUES=(-f "${ENV_DIR}/values.yaml")
  [[ -f "${ENV_DIR}/terraform.yaml" ]] && ENV_VALUES+=(-f "${ENV_DIR}/terraform.yaml")
  if [[ -f "${ENV_DIR}/overlays.txt" ]]; then
    local o
    while read -r o; do [[ -n "${o}" && "${o}" != \#* ]] && ENV_VALUES+=(-f "${GEN_DIR}/environments/overlays/${o}"); done < "${ENV_DIR}/overlays.txt"
  fi
  ENV_VALUES+=(-f "${ENV_DIR}/generated-images.yaml")
  # The log-platform chart: the tenants' rendered values FIRST, so the
  # environment and its overlays can override them (e.g. no-kafka.yaml).
  PLATFORM_VALUES=(-f "${GEN_DIR}/rendered/values-tenants.yaml" "${ENV_VALUES[@]}")
}

# value_of <yaml path, dot-separated>: read a value from the environment file.
value_of() {
  python3 -c "import yaml,sys
v=yaml.safe_load(open(sys.argv[1])) or {}
for k in sys.argv[2].split('.'): v=(v or {}).get(k)
print('' if v is None else str(v).lower() if isinstance(v, bool) else v)" "${ENV_DIR}/values.yaml" "$1"
}

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { printf '%s[generic]%s %s\n' "$BLUE"   "$NC" "$*" >&2; }
ok()   { printf '%s[generic]%s %s\n' "$GREEN"  "$NC" "$*" >&2; }
warn() { printf '%s[generic]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s[generic]%s %s\n' "$RED"    "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

need() { local c; for c in "$@"; do command -v "$c" >/dev/null || die "'$c' is required"; done; }

helm_repos() {
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update >/dev/null
  helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
  helm repo add strimzi https://strimzi.io/charts/ --force-update >/dev/null
  helm repo update grafana grafana-community external-secrets open-telemetry strimzi >/dev/null
}

# Refuse to touch a cluster that isn't the one environments/<env>/cluster.env names.
require_context() {
  need kubectl
  local want="${KUBE_CONTEXT:?set KUBE_CONTEXT in environments/<env>/cluster.env}" have
  have="$(kubectl config current-context)"
  [[ "${have}" == "${want}" ]] || die "kubectl context is '${have}', cluster.env says '${want}'"
  kubectl get --raw /readyz >/dev/null || die "API server of ${want} not reachable"
  log "cluster: ${want}"
}

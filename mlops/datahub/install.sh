#!/usr/bin/env bash
# DataHub (metadata catalog) with its prerequisites: MySQL, OpenSearch, Kafka.
# Chart defaults, single replicas. Generated credentials are kept in
# .state/mlops-datahub.env (gitignored).
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
CREDS="${LAB_ROOT}/.state/mlops-datahub.env"
DATAHUB_CHART_VERSION="${DATAHUB_CHART_VERSION:-1.1.12}"
PREREQ_CHART_VERSION="${PREREQ_CHART_VERSION:-0.3.1}"

check_host_disk
rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }
if [[ ! -f "${CREDS}" ]]; then
  ( umask 077; printf 'MYSQL_ROOT_PASSWORD=%s\nMYSQL_PASSWORD=%s\n' "$(rand)" "$(rand)" > "${CREDS}" )
fi
# shellcheck disable=SC1090
source "${CREDS}"

log "Namespace and secrets"
kubectl create namespace datahub --dry-run=client -o yaml | kubectl apply -f -
kubectl -n datahub create secret generic mysql-secrets --dry-run=client -o yaml \
  --from-literal=mysql-root-password="${MYSQL_ROOT_PASSWORD}" --from-literal=mysql-password="${MYSQL_PASSWORD}" \
  --from-literal=mysql-replication-password="${MYSQL_PASSWORD}" | kubectl apply -f -

# cp1 has 8 GiB and runs etcd: keep these JVMs off it while they are scheduled.
kubectl cordon cp1 >/dev/null
trap 'kubectl uncordon cp1 >/dev/null' EXIT

helm repo add datahub https://helm.datahubproject.io/ >/dev/null 2>&1 || true
log "Prerequisites (chart ${PREREQ_CHART_VERSION}): MySQL, OpenSearch, Kafka"
helm upgrade --install prerequisites datahub/datahub-prerequisites --version "${PREREQ_CHART_VERSION}" -n datahub --wait --timeout 20m \
  --set opensearch.serviceMonitor.enabled=false  # chart 0.3.1 does not render without this (nil pointer in the OpenSearch subchart)
log "DataHub (chart ${DATAHUB_CHART_VERSION})"
helm upgrade --install datahub datahub/datahub --version "${DATAHUB_CHART_VERSION}" -n datahub --wait --timeout 30m
kubectl -n datahub get pods

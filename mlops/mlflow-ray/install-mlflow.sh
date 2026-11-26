#!/usr/bin/env bash
# MLflow (tracking + registry) with PostgreSQL and an S3 store, basic-auth on.
# Generated credentials are kept in .state/mlops-mlflow.env (gitignored).
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
HERE="${MLOPS_ROOT}/mlflow-ray"
CREDS="${LAB_ROOT}/.state/mlops-mlflow.env"

check_host_disk
rand() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-20}"; }
if [[ ! -f "${CREDS}" ]]; then
  ( umask 077; cat > "${CREDS}" <<ENV
POSTGRES_PASSWORD=$(rand)
MLFLOW_ADMIN_PASSWORD=$(rand)
MLFLOW_FLASK_SERVER_SECRET_KEY=$(rand 32)
AWS_ACCESS_KEY_ID=mlflow$(rand 8)
AWS_SECRET_ACCESS_KEY=$(rand 32)
ENV
  )
fi
# shellcheck disable=SC1090
source "${CREDS}"

log "Namespace and secrets"
kubectl create namespace mlflow --dry-run=client -o yaml | kubectl apply -f -
kubectl -n mlflow create secret generic mlflow-credentials --from-env-file="${CREDS}" --dry-run=client -o yaml | kubectl apply -f -
log "PostgreSQL, S3 store, MLflow"
kubectl apply -f "${HERE}/mlflow.yaml"
kubectl -n mlflow rollout status deploy/postgres deploy/s3 --timeout=5m

# Identities added later with `weed shell s3.configure` (tenant.sh) are stored in
# the filer and replace the ones from the static file, so register the MLflow
# identity there as well, and create its bucket.
log "S3 identity and bucket for MLflow"
kubectl -n mlflow exec deploy/s3 -- sh -c "
  echo 's3.bucket.create -name mlflow' | weed shell >/dev/null 2>&1
  echo 's3.configure -user mlflow -access_key ${AWS_ACCESS_KEY_ID} -secret_key ${AWS_SECRET_ACCESS_KEY} -actions Admin,Read,Write,List,Tagging -apply' | weed shell >/dev/null 2>&1"
kubectl -n mlflow rollout status deploy/mlflow --timeout=10m

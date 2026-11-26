#!/usr/bin/env bash
# lakeFS (data versioning) as a shared service for both candidates.
# Metadata in its own PostgreSQL; data in a dedicated bucket on the lab's
# existing S3 store (the SeaweedFS installed with MLflow).
# Generated credentials are kept in .state/mlops-lakefs.env (gitignored).
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
HERE="${MLOPS_ROOT}/lakefs"
CREDS="${LAB_ROOT}/.state/mlops-lakefs.env"
LAKEFS_CHART_VERSION="${LAKEFS_CHART_VERSION:-1.16.1}"

check_host_disk
rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-20}"; }
if [[ ! -f "${CREDS}" ]]; then
  pg="$(rand)"
  ( umask 077; cat > "${CREDS}" <<ENV
POSTGRES_PASSWORD=${pg}
DATABASE_URL=postgres://lakefs:${pg}@postgres.lakefs.svc.cluster.local:5432/lakefs?sslmode=disable
AUTH_ENCRYPT_SECRET_KEY=$(rand 40)
BLOCKSTORE_ACCESS_KEY=lakefs$(rand 8)
BLOCKSTORE_SECRET_KEY=$(rand 32)
LAKEFS_ACCESS_KEY=AKIA$(rand 16 | tr 'a-z' 'A-Z')
LAKEFS_SECRET_KEY=$(rand 40)
ENV
  )
fi
# shellcheck disable=SC1090
source "${CREDS}"

log "Namespace, secret, PostgreSQL"
kubectl create namespace lakefs --dry-run=client -o yaml | kubectl apply -f -
kubectl -n lakefs create secret generic lakefs-credentials --from-env-file="${CREDS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/postgres.yaml"
kubectl -n lakefs rollout status deploy/postgres --timeout=5m

log "Backing bucket and identity on the S3 store"
kubectl -n mlflow exec deploy/s3 -- sh -c "
  echo 's3.bucket.create -name lakefs' | weed shell >/dev/null 2>&1
  echo 's3.configure -user lakefs -access_key ${BLOCKSTORE_ACCESS_KEY} -secret_key ${BLOCKSTORE_SECRET_KEY} -buckets lakefs -actions Read,Write,List,Tagging -apply' | weed shell >/dev/null 2>&1"

log "lakeFS (chart ${LAKEFS_CHART_VERSION})"
helm repo add lakefs https://charts.lakefs.io >/dev/null 2>&1 || true
helm upgrade --install lakefs lakefs/lakefs --version "${LAKEFS_CHART_VERSION}" -n lakefs -f "${HERE}/values.yaml" --wait --timeout 10m
kubectl -n lakefs get pods

# The installation.* settings did not create the admin user on first start, so
# run the one-time setup explicitly (it refuses to run twice).
if kubectl -n lakefs exec deploy/lakefs -- wget -qO- localhost:8000/api/v1/setup_lakefs | grep -q not_initialized; then
  log "One-time setup: admin user"
  kubectl -n lakefs exec deploy/lakefs -- sh -c 'lakefs setup --config /etc/lakefs/config.yaml --user-name admin \
    --access-key-id "$LAKEFS_INSTALLATION_ACCESS_KEY_ID" --secret-access-key "$LAKEFS_INSTALLATION_SECRET_ACCESS_KEY"' | grep -viE 'secret|access_key' || true
fi

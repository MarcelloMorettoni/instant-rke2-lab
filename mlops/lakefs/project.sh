#!/usr/bin/env bash
# Gives a project (namespace) a lakeFS repository and the Secret `data-store`
# that switches the W3 pipelines from the plain bucket to lakeFS.
#
#   project.sh <namespace> <repository>
#
# Open-source lakeFS has a single user: every project gets the same admin key,
# so this is NOT tenant isolation (see findings).
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
NS="${1:?namespace}"; REPO="${2:?repository}"
# shellcheck disable=SC1090
source "${LAB_ROOT}/.state/mlops-lakefs.env"

log "Repository ${REPO}"
kubectl -n lakefs exec deploy/lakefs -- env LAKECTL_SERVER_ENDPOINT_URL=http://localhost:8000 \
  LAKECTL_CREDENTIALS_ACCESS_KEY_ID="${LAKEFS_ACCESS_KEY}" LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY="${LAKEFS_SECRET_KEY}" \
  lakectl repo create "lakefs://${REPO}" "s3://lakefs/${REPO}" 2>&1 | grep -vi "already exists" || true

log "Secret data-store in ${NS}"
kubectl -n "${NS}" create secret generic data-store --dry-run=client -o yaml \
  --from-literal=DATA_STORE=lakefs \
  --from-literal=LAKEFS_ENDPOINT=http://lakefs.lakefs.svc.cluster.local \
  --from-literal=LAKEFS_REPO="${REPO}" \
  --from-literal=LAKEFS_ACCESS_KEY_ID="${LAKEFS_ACCESS_KEY}" \
  --from-literal=LAKEFS_SECRET_ACCESS_KEY="${LAKEFS_SECRET_KEY}" | kubectl apply -f -
kubectl -n "${NS}" create configmap testkit --from-file="${MLOPS_ROOT}/testkit/" --dry-run=client -o yaml | kubectl apply -f -

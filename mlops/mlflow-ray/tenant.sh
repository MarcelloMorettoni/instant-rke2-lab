#!/usr/bin/env bash
# Creates one project ("tenant") for the MLflow + Ray candidate.
#
# There is no platform object for this (Kubeflow has Profile), so this script is
# the wrapper: namespace, quota + default limits, network isolation, an MLflow
# user, an S3 identity limited to the project's bucket, and the shared test kit.
#
#   tenant.sh <name> [cpu-requests] [memory-requests]
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
NAME="${1:?tenant name}"; CPU="${2:-8}"; MEM="${3:-16Gi}"
CREDS="${LAB_ROOT}/.state/mlops-mlflow.env"
# shellcheck disable=SC1090
source "${CREDS}"
rand() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-20}"; }
VAR="TENANT_$(echo "${NAME}" | tr 'a-z-' 'A-Z_')"
if ! grep -q "^${VAR}_MLFLOW_PASSWORD=" "${CREDS}"; then
  ( umask 077; { echo "${VAR}_MLFLOW_PASSWORD=$(rand 16)"; echo "${VAR}_S3_ACCESS_KEY=${NAME//-/}$(rand 8)"; echo "${VAR}_S3_SECRET_KEY=$(rand 32)"; } >> "${CREDS}" )
  # shellcheck disable=SC1090
  source "${CREDS}"
fi
mlflow_pw_var="${VAR}_MLFLOW_PASSWORD"; ak_var="${VAR}_S3_ACCESS_KEY"; sk_var="${VAR}_S3_SECRET_KEY"

log "Namespace, quota, default limits, network policy: ${NAME}"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAME}
  labels: {mlops.lab/tenant: "${NAME}", pod-security.kubernetes.io/enforce: baseline}
---
apiVersion: v1
kind: ResourceQuota
metadata: {name: tenant-quota, namespace: ${NAME}}
spec:
  hard: {requests.cpu: "${CPU}", requests.memory: ${MEM}, pods: "30", persistentvolumeclaims: "5", requests.nvidia.com/gpu: "0"}
---
apiVersion: v1
kind: LimitRange
metadata: {name: tenant-defaults, namespace: ${NAME}}
spec:
  limits:
  - type: Container
    defaultRequest: {cpu: 100m, memory: 128Mi}
    default: {cpu: "1", memory: 1Gi}
---
# Only pods of the same project may connect in; egress stays open. The KubeRay
# operator is the exception: it polls each Ray head's dashboard API for job state.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: same-tenant-only, namespace: ${NAME}}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ray-system}}
    ports: [{port: 8265}, {port: 8000}]
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: workload, namespace: ${NAME}}
---
# Lets pipeline steps create Ray jobs/services in their own project only.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: workload, namespace: ${NAME}}
rules:
- {apiGroups: [ray.io], resources: [rayjobs, rayclusters, rayservices, raycronjobs], verbs: ["*"]}
- {apiGroups: [argoproj.io], resources: [workflowtaskresults], verbs: [create, patch]}
- {apiGroups: [""], resources: [pods, pods/log, services], verbs: [get, list, watch]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: workload, namespace: ${NAME}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: workload}
subjects: [{kind: ServiceAccount, name: workload, namespace: ${NAME}}]
YAML

log "MLflow user ${NAME}"
kubectl -n mlflow exec -i deploy/mlflow -- python - "${NAME}" "${!mlflow_pw_var}" <<'PY'
import os, sys, requests
name, pw = sys.argv[1:3]
auth = ("admin", os.environ["MLFLOW_ADMIN_PASSWORD"])
r = requests.post("http://localhost:5000/api/2.0/mlflow/users/create", json={"username": name, "password": pw}, auth=auth)
if r.status_code != 200:  # exists: reset the password so the secret stays valid
    r = requests.patch("http://localhost:5000/api/2.0/mlflow/users/update-password", json={"username": name, "password": pw}, auth=auth)
print("mlflow user:", r.status_code)
PY
kubectl -n "${NAME}" create secret generic mlflow-client --dry-run=client -o yaml \
  --from-literal=MLFLOW_TRACKING_URI=http://mlflow.mlflow.svc.cluster.local:5000 \
  --from-literal=MLFLOW_TRACKING_USERNAME="${NAME}" \
  --from-literal=MLFLOW_TRACKING_PASSWORD="${!mlflow_pw_var}" | kubectl apply -f -

log "S3 bucket and identity ${NAME}"
kubectl -n mlflow exec deploy/s3 -- sh -c "
  echo 's3.bucket.create -name ${NAME}' | weed shell >/dev/null 2>&1
  echo 's3.configure -user ${NAME} -access_key ${!ak_var} -secret_key ${!sk_var} -buckets ${NAME} -actions Read,Write,List,Tagging -apply' | weed shell 2>&1 | grep -ciE 'error' || true"
kubectl -n "${NAME}" create secret generic s3-client --dry-run=client -o yaml \
  --from-literal=S3_ENDPOINT=http://s3.mlflow.svc.cluster.local:8333 \
  --from-literal=S3_BUCKET="${NAME}" \
  --from-literal=AWS_ACCESS_KEY_ID="${!ak_var}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${!sk_var}" | kubectl apply -f -

log "Test kit"
kubectl -n "${NAME}" create configmap testkit --from-file="${MLOPS_ROOT}/testkit/" --dry-run=client -o yaml | kubectl apply -f -

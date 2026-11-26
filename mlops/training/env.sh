# Source this once in every terminal you use for the training:
#
#   source mlops/training/env.sh
#
# It points kubectl at the lab cluster (this terminal only) and adds four helpers.
_lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export KUBECONFIG="${_lab_root}/.state/kubeconfig"
export KF=kubeflow-user-example-com     # the Kubeflow project used in the training
export MR=mr-alpha                      # the MLflow + Ray project used in the training

# Python in the "workstation" pod of each project: test kit on the path, project credentials in the environment.
#   kf-kit - < script.py      mr-kit -c 'print(1)'
kf-kit() { kubectl -n "${KF}" exec -i deploy/kit -c kit -- python -W ignore "$@"; }
mr-kit() { kubectl -n "${MR}" exec -i deploy/kit -c kit -- python -W ignore "$@"; }

# Compiles a Kubeflow pipeline file in the Kubeflow workstation pod: kf-compile path/to/name.py -> /tmp/name.yaml there.
# (The pod's environment says the data lives in lakeFS, so the compiled pipeline reads from lakeFS.)
kf-compile() {
  local name; name="$(basename "$1" .py)"
  kubectl -n "${KF}" exec -i deploy/kit -c kit -- sh -c 'cat > /tmp/w3_pipeline.py' < "${_lab_root}/mlops/kubeflow/workloads/w3_pipeline.py" &&
  kubectl -n "${KF}" exec -i deploy/kit -c kit -- sh -c "cat > /tmp/${name}.py && cd /tmp && python -W ignore ${name}.py /tmp/${name}.yaml && echo compiled /tmp/${name}.yaml" < "$1"
}

# The lakeFS command line, run inside the lakeFS pod with the admin key.
lakectl() {
  ( source "${_lab_root}/.state/mlops-lakefs.env"
    kubectl -n lakefs exec -i deploy/lakefs -- env LAKECTL_SERVER_ENDPOINT_URL=http://localhost:8000 \
      LAKECTL_CREDENTIALS_ACCESS_KEY_ID="${LAKEFS_ACCESS_KEY}" LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY="${LAKEFS_SECRET_KEY}" \
      lakectl "$@" )
}

# The DataHub command line, run inside the ingestion pod. The first call logs in
# with the default account and creates an access token (kept in the pod, valid one month).
#   datahub-ingest mlops/datahub/recipes/mlflow.yml
_datahub_token='[ -s /tmp/token ] || python - <<PY
import requests
s = requests.Session()
s.post("http://datahub-datahub-frontend:9002/logIn", json={"username": "datahub", "password": "datahub"}).raise_for_status()
q = {"query": "mutation { createAccessToken(input: {type: PERSONAL, actorUrn: \\"urn:li:corpuser:datahub\\", duration: ONE_MONTH, name: \\"lab-ingest\\"}) { accessToken } }"}
open("/tmp/token", "w").write(s.post("http://datahub-datahub-frontend:9002/api/v2/graphql", json=q).json()["data"]["createAccessToken"]["accessToken"])
PY
export DATAHUB_TOKEN="$(cat /tmp/token)" DATAHUB_GMS_TOKEN="$(cat /tmp/token)"'
datahub() { kubectl -n datahub exec -i deploy/ingest -- bash -c "${_datahub_token}"'; datahub "$@" 2>&1 | grep -vE "Warning|warn\("' -- "$@"; }
datahub-ingest() { kubectl -n datahub exec -i deploy/ingest -- bash -c 'cat > /tmp/recipe.yml; '"${_datahub_token}"'; datahub ingest -c /tmp/recipe.yml 2>&1 | grep -vE "Warning|warn\("' < "$1"; }

# Python in the ingestion pod, for small scripts against the DataHub API.
datahub-py() { kubectl -n datahub exec -i deploy/ingest -- python "$@"; }

echo "lab environment loaded: KUBECONFIG=${KUBECONFIG}  KF=${KF}  MR=${MR}"

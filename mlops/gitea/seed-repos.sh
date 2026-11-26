#!/usr/bin/env bash
# Puts the two lesson repositories into Gitea, replacing what is there (code and CI history):
#   lab/my-model-kubeflow     from mlops/training/repos/my-model-kubeflow
#   lab/my-model-mlflow-ray   from mlops/training/repos/my-model-mlflow-ray
# The seeding commit carries "[skip ci]", so it starts no pipeline.
#   mlops/gitea/seed-repos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck disable=SC1090
source "${LAB_ROOT}/.state/mlops-gitea.env"
port=3917
kubectl -n gitea port-forward svc/gitea "${port}:3000" --address 127.0.0.1 >/dev/null 2>&1 &
pf=$!
work="$(mktemp -d)"
trap 'kill "${pf}" 2>/dev/null || true; rm -rf "${work}"' EXIT
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:${port}/api/healthz" >/dev/null && break; sleep 1; done

# The password goes to git through a header, not through the URL or the command line.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader
GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s:%s' "${GITEA_USER}" "${GITEA_PASSWORD}" | base64 -w0)"
export GIT_CONFIG_VALUE_0

for repo in my-model-kubeflow my-model-mlflow-ray; do
  # Delete first, so the CI history of an earlier pass goes too.
  curl -s -o /dev/null -X DELETE -H "${GIT_CONFIG_VALUE_0}" "http://127.0.0.1:${port}/api/v1/repos/${GITEA_USER}/${repo}" || true
  cp -r "${MLOPS_ROOT}/training/repos/${repo}" "${work}/${repo}"
  ( cd "${work}/${repo}"
    git init -q -b main
    git add -A
    git -c user.name="${GITEA_USER}" -c user.email="${GITEA_USER}@lab.invalid" commit -q -m "Starting point of the lesson [skip ci]"
    git push -q --force "http://127.0.0.1:${port}/${GITEA_USER}/${repo}.git" main 2>&1 | grep -v "^remote:" || true )
  echo "seeded ${GITEA_USER}/${repo}"
done

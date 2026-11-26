#!/usr/bin/env bash
# Gitea for the training lessons: git server with a web console and CI.
#   mlops/gitea/install.sh
# Creates the namespace gitea, one admin account (kept in .state/mlops-gitea.env,
# gitignored), a CI runner in each training project, and the two lesson
# repositories (seed-repos.sh). Safe to run again.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
HERE="${MLOPS_ROOT}/gitea"
CREDS="${LAB_ROOT}/.state/mlops-gitea.env"
KF_NS="${KF_NS:-kubeflow-user-example-com}"
MR_NS="${MR_NS:-mr-alpha}"

if [[ ! -f "${CREDS}" ]]; then
  ( umask 077; printf 'GITEA_USER=lab\nGITEA_PASSWORD=%s\n' "$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)" > "${CREDS}" )
fi
# shellcheck disable=SC1090
source "${CREDS}"

echo "== Gitea"
kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/gitea.yaml"
kubectl -n gitea rollout status deploy/gitea --timeout=5m

echo "== Account ${GITEA_USER}"
if ! kubectl -n gitea exec deploy/gitea -- gitea admin user list | awk '{print $2}' | grep -qx "${GITEA_USER}"; then
  kubectl -n gitea exec deploy/gitea -- gitea admin user create --admin --username "${GITEA_USER}" \
    --password "${GITEA_PASSWORD}" --email "${GITEA_USER}@lab.invalid" --must-change-password=false | tail -1
fi

echo "== CI runners"
for ns in "${KF_NS}" "${MR_NS}"; do
  if ! kubectl -n "${ns}" get secret gitea-runner >/dev/null 2>&1; then
    token="$(kubectl -n gitea exec deploy/gitea -- gitea actions generate-runner-token | tail -1)"
    kubectl -n "${ns}" create secret generic gitea-runner --from-literal=token="${token}"
  fi
done
kubectl -n "${KF_NS}" apply -f "${HERE}/runner-kubeflow.yaml"
kubectl -n "${MR_NS}" apply -f "${HERE}/runner-mlflow-ray.yaml"
kubectl -n "${KF_NS}" rollout status deploy/ci-runner --timeout=10m
kubectl -n "${MR_NS}" rollout status deploy/ci-runner --timeout=10m

"${HERE}/seed-repos.sh"
echo "Gitea is ready. Console: http://localhost:3000 after mlops/training/lab.sh up (login: mlops/training/lab.sh logins)."

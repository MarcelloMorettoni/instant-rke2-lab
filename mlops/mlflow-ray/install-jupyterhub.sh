#!/usr/bin/env bash
# JupyterHub (Zero to JupyterHub chart) as the notebook layer for MLflow + Ray.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
JUPYTERHUB_CHART_VERSION="${JUPYTERHUB_CHART_VERSION:-4.4.5}"
check_host_disk
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/ >/dev/null 2>&1 || true
helm repo update jupyterhub >/dev/null
log "JupyterHub chart ${JUPYTERHUB_CHART_VERSION}"
helm upgrade --install jupyterhub jupyterhub/jupyterhub --version "${JUPYTERHUB_CHART_VERSION}" \
  --namespace jhub --create-namespace --wait --timeout 10m \
  --values "${MLOPS_ROOT}/mlflow-ray/jupyterhub-values.yaml"
kubectl apply -f "${MLOPS_ROOT}/mlflow-ray/jupyterhub-cilium.yaml"
kubectl -n jhub get pods

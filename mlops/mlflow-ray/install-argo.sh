#!/usr/bin/env bash
# Argo Workflows as the pipeline layer of the MLflow + Ray candidate.
#
# Kubeflow already runs its own cluster-wide Argo controller (v3.7.3) on this
# lab cluster, so this one stays on the 3.7 line (same CRDs, not reinstalled)
# and uses an instance ID: each controller only touches workflows labelled for it.
#
# The web console (argo-server) is on, with auth mode "server": no login, it acts
# with its own ServiceAccount. Lab only: it is reached through a port-forward on
# 127.0.0.1 (mlops/training/lab.sh up -> http://localhost:2746), never exposed.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
ARGO_CHART_VERSION="${ARGO_CHART_VERSION:-0.47.5}"   # Argo Workflows v3.7.11
check_host_disk
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
crds=true; kubectl get crd workflows.argoproj.io >/dev/null 2>&1 && crds=false
log "Argo Workflows chart ${ARGO_CHART_VERSION} (install CRDs: ${crds})"
helm upgrade --install argo-workflows argo/argo-workflows --version "${ARGO_CHART_VERSION}" \
  --namespace argo --create-namespace --wait --timeout 8m \
  --set crds.install="${crds}" \
  --set controller.instanceID.enabled=true --set controller.instanceID.explicitID=mlflow-ray \
  --set controller.workflowNamespaces='{mr-alpha,mr-beta}' \
  --set controller.resources.requests.cpu=100m --set controller.resources.requests.memory=128Mi \
  --set server.enabled=true --set 'server.authModes={server}' --set server.secure=false \
  --set server.resources.requests.cpu=50m --set server.resources.requests.memory=96Mi \
  --set-string server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=node-role.kubernetes.io/control-plane \
  --set-string server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=DoesNotExist \
  --set workflow.serviceAccount.create=false \
  --set-string controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=node-role.kubernetes.io/control-plane \
  --set-string controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=DoesNotExist
kubectl -n argo get pods

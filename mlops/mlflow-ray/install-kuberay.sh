#!/usr/bin/env bash
# KubeRay operator (RayCluster / RayJob / RayService CRDs), cluster-wide.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
KUBERAY_VERSION="${KUBERAY_VERSION:-1.7.3}"
check_host_disk
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null 2>&1 || true
helm repo update kuberay >/dev/null
log "KubeRay operator ${KUBERAY_VERSION}"
helm upgrade --install kuberay-operator kuberay/kuberay-operator --version "${KUBERAY_VERSION}" \
  --namespace ray-system --create-namespace --wait --timeout 5m \
  --set resources.requests.cpu=100m --set resources.requests.memory=256Mi
kubectl -n ray-system get pods

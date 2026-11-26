#!/usr/bin/env bash
# Kubeflow Model Registry. It ships in kubeflow/manifests but is not part of the
# single-command install, so it is a separate, documented step.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

SRC="${MLOPS_CACHE}/kubeflow-manifests-${KUBEFLOW_MANIFESTS_VERSION}/applications/model-registry/upstream"
ensure_kustomize

log "Model Registry server + MySQL"
"${KUSTOMIZE}" build "${SRC}/overlays/db" | kubectl apply -n kubeflow -f -
"${KUSTOMIZE}" build "${SRC}/options/istio" | kubectl apply -n kubeflow -f -

log "Model Registry UI"
"${KUSTOMIZE}" build "${SRC}/options/ui/overlays/istio" | kubectl apply -n kubeflow -f -

log "Dashboard menu link"
if ! kubectl -n kubeflow get cm centraldashboard-config -o jsonpath='{.data.links}' | grep -q '/model-registry/'; then
  kubectl -n kubeflow get cm centraldashboard-config -o json \
    | jq '.data.links |= (fromjson | .menuLinks += [{"icon":"assignment","link":"/model-registry/","text":"Model Registry","type":"item"}] | tojson)' \
    | kubectl apply -n kubeflow -f -
fi

kubectl -n kubeflow wait --for=condition=available --timeout=5m \
  deployment/model-registry-db deployment/model-registry-deployment deployment/model-registry-ui

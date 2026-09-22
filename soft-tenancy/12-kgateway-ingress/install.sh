#!/usr/bin/env bash
# Step 12: kgateway as the ingress. One Gateway per tenant, one for the platform.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
command -v helm >/dev/null || die "helm not installed. See https://helm.sh/docs/intro/install/"

# Gateway API CRDs. Some distributions (or another ingress, such as a bundled
# Traefik) install them already. Never overwrite CRDs someone else manages.
if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  have="$(kubectl get crd gateways.gateway.networking.k8s.io \
          -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
  warn "Gateway API CRDs already present (bundle ${have:-unknown}); leaving them alone."
  warn "kgateway ${KGATEWAY_VERSION} is built against ${GATEWAY_API_VERSION}; upgrade them if routes misbehave."
else
  log "Installing Gateway API ${GATEWAY_API_VERSION} CRDs (standard channel)"
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
fi

log "Installing kgateway ${KGATEWAY_VERSION} into ${GW_NS}"
helm upgrade --install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version "${KGATEWAY_VERSION}" --namespace "${GW_NS}" --create-namespace --wait
helm upgrade --install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version "${KGATEWAY_VERSION}" --namespace "${GW_NS}" --wait --timeout 5m

log "Waiting for the kgateway GatewayClass"
for _ in $(seq 1 60); do
  kubectl get gatewayclass kgateway >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=condition=Accepted gatewayclass/kgateway --timeout=120s

# Policies first, so every proxy starts locked down.
log "Applying network policies, RBAC, Gateways and the Grafana route"
kubectl apply -f "${HERE}/network-policies.yaml"
kubectl apply -f "${HERE}/rbac.yaml"
kubectl apply -f "${HERE}/gateways.yaml"
kubectl apply -f "${HERE}/grafana-route.yaml"
for gw in tenant-a tenant-b platform; do
  kubectl -n "${GW_NS}" wait --for=condition=Programmed "gateway/${gw}" --timeout=180s
done

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
ok "Step 12 done. Gateways listen on ${NODE_IP}:"
echo "    tenant-a  :30180   *.tenant-a.lab"
echo "    tenant-b  :30181   *.tenant-b.lab"
echo "    platform  :30182   grafana.platform.lab"
echo
echo "Now each tenant publishes its own app:"
echo "    kubectl --as alice apply -f 12-kgateway-ingress/route-tenant-a.yaml"
echo "    kubectl --as bob   apply -f 12-kgateway-ingress/route-tenant-b.yaml"
echo
echo "Grafana from this host:  curl -H 'Host: grafana.platform.lab' http://${NODE_IP}:30182/api/health"
echo "In a browser: add '${NODE_IP} grafana.platform.lab' to /etc/hosts, open http://grafana.platform.lab:30182"

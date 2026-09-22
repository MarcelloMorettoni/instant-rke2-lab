#!/usr/bin/env bash
# Step 12: kgateway as the ingress. One Gateway per tenant, one for the platform.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster
# kgateway itself is already there from step 07 (the read gateway); this only
# re-applies it, or installs it if you run step 12 on its own.
install_kgateway

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

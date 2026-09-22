#!/usr/bin/env bash
# Step 13: prove the ingress (kgateway) keeps tenants apart.
#   ok   = must work          fail = must be blocked / refused
# Runs from the lab host, which reaches the gateways' NodePorts like any client.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
require_cluster

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
A_POD_IP="$(kubectl -n tenant-a get pod -l app=web -o jsonpath='{.items[0].status.podIP}')"
GA="http://${NODE_IP}:30180"; GB="http://${NODE_IP}:30181"; GC="http://${NODE_IP}:30183"; GP="http://${NODE_IP}:30182"

body_is() { local want=$1; shift; [[ "$(curl -s -m 5 "$@")" == "$want" ]]; }
code_is() { local want=$1; shift; [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$@")" == "$want" ]]; }
accepted() {  # accepted <ns> <route>: did the Gateway accept this HTTPRoute?
  kubectl -n "$1" get httproute "$2" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' | grep -qx True
}

cleanup() {
  kubectl -n tenant-b delete httproute hijack steal rogue --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n tenant-b delete backends.gateway.kgateway.dev rogue-to-a --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n tenant-a delete httproute control --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n tenant-a delete backends.gateway.kgateway.dev control-to-a --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Routes applied a moment ago take a few seconds to reach the proxies.
log "Waiting for the routes to be programmed..."
for _ in $(seq 1 45); do
  body_is "hello from tenant-a" -H 'Host: web.tenant-a.lab' "$GA/" &&
    body_is "hello from tenant-b" -H 'Host: web.tenant-b.lab' "$GB/" &&
    body_is "hello from tenant-c" -H 'Host: web.tenant-c.lab' "$GC/" &&
    code_is 200 -H 'Host: grafana.platform.lab' "$GP/api/health" && break
  sleep 2
done

echo; log "── Through the front door"
check "web.tenant-a.lab on tenant-a's gateway"          ok   body_is "hello from tenant-a" -H 'Host: web.tenant-a.lab' "$GA/"
check "web.tenant-b.lab on tenant-b's gateway"          ok   body_is "hello from tenant-b" -H 'Host: web.tenant-b.lab' "$GB/"
check "web.tenant-c.lab on tenant-c's gateway"          ok   body_is "hello from tenant-c" -H 'Host: web.tenant-c.lab' "$GC/"
check "tenant-a's gateway won't serve web.tenant-b.lab" fail body_is "hello from tenant-b" -H 'Host: web.tenant-b.lab' "$GA/"
# Tenant a's PODS may call tenant c; tenant a's GATEWAY still serves tenant a only.
check "tenant-a's gateway won't serve web.tenant-c.lab" fail body_is "hello from tenant-c" -H 'Host: web.tenant-c.lab' "$GA/"
check "grafana.platform.lab on the platform gateway"    ok   code_is 200 -H 'Host: grafana.platform.lab' "$GP/api/health"
# Tenants have no egress to kgateway-system: inside the cluster, use service names.
check "tenant-a pod -> its gateway from inside"         fail in_tenant tenant-a \
      "curl -s -m 3 -o /dev/null -H 'Host: web.tenant-a.lab' http://${NODE_IP}:30180/"

echo; log "── Gateway API rules (as bob, tenant-b's developer)"
kubectl --as bob apply -f - >/dev/null <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: hijack, namespace: tenant-b}
spec:
  parentRefs: [{name: tenant-a, namespace: kgateway-system}]
  hostnames: [web.tenant-a.lab]
  rules: [{backendRefs: [{name: web, port: 80}]}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: steal, namespace: tenant-b}
spec:
  parentRefs: [{name: tenant-b, namespace: kgateway-system}]
  hostnames: [steal.tenant-b.lab]
  rules: [{backendRefs: [{name: web, namespace: tenant-a, port: 80}]}]
EOF
sleep 8
check "bob's route on tenant-a's gateway is rejected"   fail accepted tenant-b hijack
check "web.tenant-a.lab still answers tenant-a"         ok   body_is "hello from tenant-a" -H 'Host: web.tenant-a.lab' "$GA/"
check "bob's route can't use tenant-a's service"        fail body_is "hello from tenant-a" -H 'Host: steal.tenant-b.lab' "$GB/"
check "bob can't create ReferenceGrants"                fail kubectl --as bob -n tenant-b auth can-i create referencegrants.gateway.networking.k8s.io
check "bob can't create kgateway Backends"              fail kubectl --as bob -n tenant-b auth can-i create backends.gateway.kgateway.dev
check "bob can't change Gateways"                       fail kubectl --as bob -n kgateway-system auth can-i update gateways.gateway.networking.k8s.io

echo; log "── Network backstop: a rogue Backend (as if RBAC had slipped)"
# Control first: the same kind of Static Backend on tenant-a's own gateway works,
# so a failure below is Cilium's doing, not a broken Backend.
kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata: {name: control-to-a, namespace: tenant-a}
spec:
  type: Static
  static: {hosts: [{host: ${A_POD_IP}, port: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: control, namespace: tenant-a}
spec:
  parentRefs: [{name: tenant-a, namespace: kgateway-system}]
  hostnames: [control.tenant-a.lab]
  rules: [{backendRefs: [{group: gateway.kgateway.dev, kind: Backend, name: control-to-a}]}]
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata: {name: rogue-to-a, namespace: tenant-b}
spec:
  type: Static
  static: {hosts: [{host: ${A_POD_IP}, port: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: rogue, namespace: tenant-b}
spec:
  parentRefs: [{name: tenant-b, namespace: kgateway-system}]
  hostnames: [rogue.tenant-b.lab]
  rules: [{backendRefs: [{group: gateway.kgateway.dev, kind: Backend, name: rogue-to-a}]}]
EOF
sleep 8
check "control: Static Backend via tenant-a's gateway"  ok   body_is "hello from tenant-a" -H 'Host: control.tenant-a.lab' "$GA/"
check "rogue: tenant-b's proxy -> tenant-a pod IP"      fail body_is "hello from tenant-a" -H 'Host: rogue.tenant-b.lab' "$GB/"

echo; log "── What Cilium dropped from tenant-b's proxy (last 2 min)"
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- hubble observe --verdict DROPPED --since 2m \
    --from-label gateway.networking.k8s.io/gateway-name=tenant-b -o compact 2>/dev/null || true
done | tail -5 || true

summary

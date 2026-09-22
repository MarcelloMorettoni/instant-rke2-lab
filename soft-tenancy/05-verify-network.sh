#!/usr/bin/env bash
# Step 05: prove the tenant isolation. Every check says what MUST happen.
#   ok   = must work          fail = must be blocked / refused
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
require_cluster

for ns in tenant-a tenant-b; do
  kubectl -n "$ns" wait --for=condition=Available deploy --all --timeout=180s >/dev/null
done

A_POD_IP="$(kubectl -n tenant-a get pod -l app=web -o jsonpath='{.items[0].status.podIP}')"
B_POD_IP="$(kubectl -n tenant-b get pod -l app=web -o jsonpath='{.items[0].status.podIP}')"
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
log "tenant-a web pod ${A_POD_IP} | tenant-b web pod ${B_POD_IP} | node ${NODE_IP}"

# Connectivity checks that expect "blocked" deliberately don't use curl -f:
# ANY HTTP answer (even a 404) means the packets got through.
reach() { in_tenant "$1" "curl -s -m 3 -o /dev/null $2"; }

echo; log "── Inside each tenant"
check "tenant-a -> its own web (service)"           ok   in_tenant tenant-a "curl -sf -m 3 http://web"
check "tenant-b -> its own web (service)"           ok   in_tenant tenant-b "curl -sf -m 3 http://web"
check "tenant-a resolves web.tenant-a"              ok   in_tenant tenant-a "dig +short web.tenant-a.svc.cluster.local | grep -q ."

echo; log "── Across tenants"
check "tenant-a -> tenant-b web via DNS name"       fail reach tenant-a "http://web.tenant-b"
check "tenant-a -> tenant-b web via pod IP"         fail reach tenant-a "http://${B_POD_IP}:8080"
check "tenant-b -> tenant-a web via pod IP"         fail reach tenant-b "http://${A_POD_IP}:8080"
check "tenant-a -> tenant-b via NodePort ${NODE_IP}:30082" \
                                                    fail reach tenant-a "http://${NODE_IP}:30082"
check "tenant-a gets NXDOMAIN for web.tenant-b"     ok   in_tenant tenant-a \
      "dig web.tenant-b.svc.cluster.local | grep -q 'status: NXDOMAIN'"

echo; log "── Egress allowlist"
check "tenant-a -> https://example.com (allowlisted)"  ok   in_tenant tenant-a "curl -sf -m 8 -o /dev/null https://example.com"
check "tenant-a -> https://github.com (not listed)"    fail reach tenant-a "https://github.com"
check "tenant-b -> https://example.com (no internet)"  fail reach tenant-b "https://example.com"
check "tenant-a -> Kubernetes API"                     fail in_tenant tenant-a \
      "curl -sk -m 3 -o /dev/null https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT/version"

echo; log "── Kubernetes guardrails (as alice, tenant-a's developer)"
RESTRICTED_SC='"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}}'
CONTAINER='"containers":[{"name":"guardrail-test","image":"busybox","command":["sleep","1"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]'
# kubectl run's default override is a JSON merge patch: it REPLACES the
# generated container list, so the override carries the full container.
try_pod() {  # try_pod <extra pod spec JSON fields>: server-side dry run as alice
  kubectl --as alice -n tenant-a run guardrail-test --image=busybox --restart=Never --dry-run=server \
    --overrides="{\"apiVersion\":\"v1\",\"spec\":{${1:+$1,}${RESTRICTED_SC},${CONTAINER}}}"
}
check "alice can create a compliant pod (control)"      ok   try_pod ""
check "PSA rejects a hostNetwork pod"                   fail try_pod '"hostNetwork":true'
check "PSA rejects a hostPath volume"                   fail try_pod '"volumes":[{"name":"h","hostPath":{"path":"/var/log"}}]'
check "alice can't write NetworkPolicies"               fail kubectl --as alice -n tenant-a auth can-i create networkpolicies.networking.k8s.io
check "alice can't write CiliumNetworkPolicies"         fail kubectl --as alice -n tenant-a auth can-i create ciliumnetworkpolicies.cilium.io
check "alice can't read tenant-b pods"                  fail kubectl --as alice -n tenant-b auth can-i list pods
check "alice can't read tenant-b secrets"               fail kubectl --as alice -n tenant-b auth can-i get secrets
check "alice can't relabel her namespace"               fail kubectl --as alice auth can-i patch namespace/tenant-a

echo; log "── Namespace admission guard"
try_ns() {  # try_ns <name> [key=value ...]: server-side dry run
  local name=$1
  shift
  {
    printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n    lab: soft-tenancy\n' "$name"
    for kv in "$@"; do printf '    %s: "%s"\n' "${kv%%=*}" "${kv#*=}"; done
  } | kubectl apply --dry-run=server -f -
}
PSS=pod-security.kubernetes.io/enforce=restricted
check "tenant-c with label + restricted (control)"      ok   try_ns tenant-c tenant=c "$PSS"
check "tenant-a-dev joins tenant a"                     ok   try_ns tenant-a-dev tenant=a "$PSS"
check "tenant-c without a tenant label"                 fail try_ns tenant-c "$PSS"
check "tenant-c without restricted PSS"                 fail try_ns tenant-c tenant=c
check "'sneaky' namespace claiming tenant=a"            fail try_ns sneaky tenant=a "$PSS"
check "tenant-a-dev claiming tenant=a-dev"              fail try_ns tenant-a-dev tenant=a-dev "$PSS"

echo; log "── Deny beats allow"
log "Applying two rogue allow policies (as if someone made a mistake)..."
cleanup_rogue() {
  kubectl -n tenant-b delete cnp rogue-allow-from-a --ignore-not-found >/dev/null
  kubectl -n tenant-a delete cnp rogue-allow-to-b --ignore-not-found >/dev/null
}
trap cleanup_rogue EXIT
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rogue-allow-from-a
  namespace: tenant-b
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: tenant-a
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rogue-allow-to-b
  namespace: tenant-a
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: tenant-b
EOF
sleep 5
check "tenant-a -> tenant-b pod IP, rogue allows in place" fail reach tenant-a "http://${B_POD_IP}:8080"
cleanup_rogue
trap - EXIT

echo; log "── What Cilium dropped (last 3 min, tenant flows)"
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --verdict DROPPED --since 3m -o compact 2>/dev/null || true
done | grep -E 'tenant-(a|b)/' | tail -15 || warn "no drops captured (is Hubble enabled?)"

summary

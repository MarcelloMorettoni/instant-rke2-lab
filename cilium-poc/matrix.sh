#!/usr/bin/env bash
# Who can reach whom, right now. Run it after each step; the README lists
# what to expect at every stage.
#
# Uses your current kubectl context (or $KUBECONFIG). Needs kubectl and curl.
# Read-only: it only runs curl inside the POC pods and port-forwards to the
# gateway proxy for a few seconds.
set -uo pipefail

GW_NS=kgateway-system
GW=cilium-poc
PF_PORT="${PF_PORT:-18080}"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# row <from> <to> <command...>: ALLOWED (with the answer) or BLOCKED.
# Any HTTP answer counts as allowed: it means the packets got through.
row() {
  local from=$1 to=$2 out
  shift 2
  if out=$("$@" 2>/dev/null | tr -d '\n'); then
    printf '  %-6s -> %-32s %sALLOWED%s  %s\n' "$from" "$to" "$GREEN" "$NC" "$out"
  else
    printf '  %-6s -> %-32s %sBLOCKED%s\n' "$from" "$to" "$RED" "$NC"
  fi
}

# from_ns <namespace> <curl args...>: curl from inside that namespace's workload.
from_ns() {
  local ns=$1
  shift
  kubectl -n "$ns" exec deploy/app -c app -- curl -s -m 3 -w ' [%{http_code}]' "$@"
}

for ns in team-a team-b; do
  kubectl -n "$ns" get deploy/app >/dev/null 2>&1 ||
    { echo "deploy/app not found in $ns: apply manifests/00 and 01 first" >&2; exit 1; }
done

echo "${BOLD}Pod to pod, through the Services${NC}"
row team-a "app.team-a (own namespace)"  from_ns team-a http://app.team-a.svc.cluster.local
row team-a "app.team-b"                  from_ns team-a http://app.team-b.svc.cluster.local
row team-b "app.team-b (own namespace)"  from_ns team-b http://app.team-b.svc.cluster.local
row team-b "app.team-a"                  from_ns team-b http://app.team-a.svc.cluster.local

GW_POD="$(kubectl -n "$GW_NS" get pod -l "gateway.networking.k8s.io/gateway-name=${GW}" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
GW_IP="$(kubectl -n "$GW_NS" get pod "$GW_POD" -o jsonpath='{.status.podIP}' 2>/dev/null)"
if [[ -z "$GW_POD" || -z "$GW_IP" ]]; then
  echo
  echo "${YELLOW}No proxy pod for Gateway ${GW} in ${GW_NS} yet: skipping the gateway rows (step 02).${NC}"
  exit 0
fi

echo
echo "${BOLD}From outside, through kgateway${NC} (port-forward to ${GW_POD})"
kubectl -n "$GW_NS" port-forward "pod/${GW_POD}" "${PF_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null' EXIT
sleep 2
if kill -0 "$PF_PID" 2>/dev/null; then
  via_gw() { curl -s -m 3 -w ' [%{http_code}]' -H "Host: $1" "http://127.0.0.1:${PF_PORT}/"; }
  row you "gateway -> team-a.poc.lab" via_gw team-a.poc.lab
  row you "gateway -> team-b.poc.lab" via_gw team-b.poc.lab
else
  echo "  ${YELLOW}port-forward failed (port ${PF_PORT} busy, or not allowed): skipped${NC}"
fi

echo
echo "${BOLD}The detour: a team pod asking the gateway for the other team${NC}"
row team-a "gateway -> team-b.poc.lab" from_ns team-a -H 'Host: team-b.poc.lab' "http://${GW_IP}:8080/"
row team-b "gateway -> team-a.poc.lab" from_ns team-b -H 'Host: team-a.poc.lab' "http://${GW_IP}:8080/"

echo
echo "${BOLD}What Cilium dropped in the last 5 minutes${NC}"
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --verdict DROPPED --since 5m \
      --namespace team-a --namespace team-b -o compact 2>/dev/null || true
done | sort | tail -n 10 | grep . || echo "  (none, or Hubble is not enabled)"

#!/usr/bin/env bash
# W4 on MLflow + Ray: first request, scale-to-zero, cold start and scale-up of
# the Ray Serve LLM endpoint. Same client and sequence as the KServe test.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"
NS="${NS:-mr-alpha}"
URL="http://smollm-serve-svc.${NS}.svc.cluster.local:8000"
kit() { kubectl -n "${NS}" exec deploy/kit -c kit -- python -W ignore /testkit/llm_client.py "$@"; }
workers() { kubectl -n "${NS}" get pods -l ray.io/group=llm --no-headers 2>/dev/null | grep -c Running || true; }
all_workers() { kubectl -n "${NS}" get pods -l ray.io/group=llm --no-headers 2>/dev/null | wc -l; }
replicas() { kubectl -n "${NS}" get rayservice smollm -o json | jq -r '.status.activeServiceStatus.applicationStatuses.smollm.serveDeploymentStatuses.SmolLM.status // "?"'; }
ts() { date -u +%T; }

echo "$(ts) state before first request: worker pods=$(all_workers) deployment=$(replicas)"
echo "$(ts) first request: $(kit once "${URL}" smollm)"
echo "$(ts) warm request:  $(kit once "${URL}" smollm)"
last=$(date +%s)
echo "$(ts) waiting for scale to zero (no Ray worker pods)..."
until [[ "$(all_workers)" == 0 ]]; do sleep 2; (( $(date +%s) - last > 900 )) && { echo "no scale to zero within 900s"; break; }; done
echo "$(ts) worker pods at zero $(( $(date +%s) - last ))s after the last request; still running: $(kubectl -n "${NS}" get pods --no-headers | grep -c 'smollm.*head') head pod"
echo "$(ts) cold request:  $(kit once "${URL}" smollm)"
echo "$(ts) worker pods before load: $(workers)"
( for _ in $(seq 1 30); do echo "$(ts) running worker pods: $(workers)"; sleep 10; done ) > "${MLOPS_CACHE}/w4-ray-replicas.log" &
watcher=$!
echo "$(ts) $(kit load "${URL}" smollm 6 180)"
kill "${watcher}" 2>/dev/null || true
echo "worker pods during load: $(awk '{print $NF}' "${MLOPS_CACHE}/w4-ray-replicas.log" | tr '\n' ' ')"
echo "$(ts) worker pods after load: $(workers)"

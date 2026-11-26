#!/usr/bin/env bash
# W4 on Kubeflow: first request, scale-to-zero, cold start and scale-up of the
# KServe LLM endpoint. Requests are sent from the kit pod inside the cluster.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"
NS="${NS:-kubeflow-user-example-com}"
URL="http://smollm-predictor.${NS}.svc.cluster.local/openai"
SEL="serving.kserve.io/inferenceservice=smollm"
kit() { kubectl -n "${NS}" exec deploy/kit -c kit -- python -W ignore /testkit/llm_client.py "$@"; }
pods() { kubectl -n "${NS}" get pods -l "${SEL}" --no-headers 2>/dev/null | grep -c Running || true; }
ts() { date -u +%T; }

echo "$(ts) warm request:  $(kit once "${URL}" smollm)"
last=$(date +%s)
echo "$(ts) waiting for scale to zero..."
until [[ "$(kubectl -n "${NS}" get pods -l "${SEL}" --no-headers 2>/dev/null | wc -l)" == 0 ]]; do sleep 2; done
echo "$(ts) scaled to zero $(( $(date +%s) - last ))s after the last request"
echo "$(ts) cold request:  $(kit once "${URL}" smollm)"
echo "$(ts) replicas before load: $(pods)"
( for _ in $(seq 1 30); do echo "$(ts) running replicas: $(pods)"; sleep 10; done ) > "${MLOPS_CACHE}/w4-replicas.log" &
watcher=$!
echo "$(ts) $(kit load "${URL}" smollm 6 180)"
kill "${watcher}" 2>/dev/null || true
echo "replicas during load: $(awk '{print $NF}' "${MLOPS_CACHE}/w4-replicas.log" | tr '\n' ' ')"
echo "$(ts) replicas after load: $(pods)"

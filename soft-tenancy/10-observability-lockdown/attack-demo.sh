#!/usr/bin/env bash
# Step 10a: why step 10 exists. Run this BEFORE and AFTER applying policies.yaml.
#
# None of the backends checks who sets X-Scope-OrgID. Any pod that can reach
# them can claim to be any tenant. Tenant pods are already blocked by their
# own baseline (step 03), but a pod in a namespace with no policy, like
# `default`, is not. This throwaway pod plays the attacker:
#   1. reads tenant b's logs, metrics, traces and profiles by claiming to be tenant-b
#   2. forges a log line into tenant a by claiming to be tenant-a
# Before the lockdown all of it works. After it, everything times out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster

LOKI="http://loki.${OBS_NS}.svc.cluster.local:3100"
MIMIR="http://mimir.${OBS_NS}.svc.cluster.local:8080"
TEMPO="http://tempo.${OBS_NS}.svc.cluster.local:3200"
PYRO="http://pyroscope.${OBS_NS}.svc.cluster.local:4040"
POD=loki-attacker
# Restricted-compliant, so it runs whatever Pod Security level `default` has.
# Strategic merge: this merges into the generated container (named like the pod).
OVERRIDES='{"apiVersion":"v1","spec":{"automountServiceAccountToken":false,
  "securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},
  "containers":[{"name":"loki-attacker",
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'

log "Starting attacker pod in namespace 'default'"
kubectl -n default delete pod "${POD}" --now --ignore-not-found >/dev/null
kubectl -n default run "${POD}" --restart=Never --image=docker.io/nicolaka/netshoot:v0.16 \
  --override-type=strategic --overrides="${OVERRIDES}" --command -- sleep 600 >/dev/null
trap 'kubectl -n default delete pod "${POD}" --now --ignore-not-found >/dev/null' EXIT
kubectl -n default wait --for=condition=Ready "pod/${POD}" --timeout=120s >/dev/null

attack() { kubectl -n default exec "${POD}" -- sh -c "$1" 2>/dev/null || true; }

NOW_NS="$(date +%s)000000000"
FORGED="{\"streams\":[{\"stream\":{\"namespace\":\"tenant-a\",\"forged\":\"true\"},\"values\":[[\"${NOW_NS}\",\"FORGED: tenant a never wrote this\"]]}]}"

AS_B="-s -m 5 -H 'X-Scope-OrgID: tenant-b'"
LOGS="$(attack "curl ${AS_B} ${LOKI}/loki/api/v1/label/namespace/values")"
METRICS="$(attack "curl ${AS_B} ${MIMIR}/prometheus/api/v1/label/namespace/values")"
TRACES="$(attack "curl ${AS_B} '${TEMPO}/api/search?limit=5'" | grep -o '"traceID"' | wc -l | tr -d ' ')"
NOW="$(date +%s)"
PROFILES="$(attack "curl ${AS_B} -X POST -H 'Content-Type: application/json' \
  -d '{\"name\":\"namespace\",\"start\":$(( (NOW - 3600) * 1000 )),\"end\":$(( NOW * 1000 ))}' \
  ${PYRO}/querier.v1.QuerierService/LabelValues")"
FORGE="$(attack "curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'X-Scope-OrgID: tenant-a' \
                 -H 'Content-Type: application/json' --data '${FORGED}' ${LOKI}/loki/api/v1/push")"

echo
echo "  read tenant-b's logs     : ${LOGS:-BLOCKED (timed out)}"
echo "  read tenant-b's metrics  : ${METRICS:-BLOCKED (timed out)}"
echo "  read tenant-b's traces   : $([[ "${TRACES:-0}" -gt 0 ]] && echo "${TRACES} traces" || echo "BLOCKED (timed out)")"
echo "  read tenant-b's profiles : ${PROFILES:-BLOCKED (timed out)}"
echo "  forge a log into tenant-a: $([[ "${FORGE}" == "204" ]] && echo "HTTP 204, accepted" || echo "BLOCKED (${FORGE:-no answer})")"
echo
echo "  Before step 10 everything works. After step 10 every line must say BLOCKED."

#!/usr/bin/env bash
# Step 10a: why step 10 exists. Run this BEFORE and AFTER applying policies.yaml.
#
# Loki doesn't check who sets X-Scope-OrgID. Any pod that can reach Loki can
# claim to be any tenant. Tenant pods are already blocked by their own
# baseline (step 03), but a pod in a namespace with no policy, like
# `default`, is not. This throwaway pod plays the attacker:
#   1. reads tenant b's logs by claiming to be tenant-b
#   2. forges a log line into tenant a by claiming to be tenant-a
# Before the lockdown both work. After it, both time out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"
require_cluster

LOKI="http://loki.${OBS_NS}.svc.cluster.local:3100"
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

READ="$(attack "curl -s -m 5 -H 'X-Scope-OrgID: tenant-b' ${LOKI}/loki/api/v1/label/namespace/values")"
FORGE="$(attack "curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'X-Scope-OrgID: tenant-a' \
                 -H 'Content-Type: application/json' --data '${FORGED}' ${LOKI}/loki/api/v1/push")"

echo
echo "  read  tenant-b's logs : ${READ:-BLOCKED (timed out)}"
echo "  forge into tenant-a   : $([[ "${FORGE}" == "204" ]] && echo "HTTP 204, accepted" || echo "BLOCKED (${FORGE:-no answer})")"
echo
echo "  Before step 10 both work. After step 10 both must say BLOCKED."

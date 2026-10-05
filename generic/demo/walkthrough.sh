#!/usr/bin/env bash
# Deploy the demo step by step (steps/), saying what each step adds and waiting
# until it's ready. For a live session with the team, use --pause.
#
#   generic/demo/walkthrough.sh --context <kube-context>               every step
#   generic/demo/walkthrough.sh --context <kube-context> --pause       stop before each step
#   generic/demo/walkthrough.sh --context <kube-context> --from 05     resume at step 05
#   generic/demo/walkthrough.sh --context <kube-context> --delete      remove the demo
#
# --context is required, and must be the current kubectl context: the script
# never guesses which cluster to change.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
STEPS="${DIR}/steps"
NS=observability
CONTEXT="" PAUSE=0 FROM=00 DELETE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --pause) PAUSE=1; shift ;;
    --from) FROM="$2"; shift 2 ;;
    --delete) DELETE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
B=$'\033[1m' G=$'\033[0;32m' Y=$'\033[1;33m' R=$'\033[0;31m' N=$'\033[0m'
[[ -n "${CONTEXT}" ]] || { echo "${R}--context <kube-context> is required${N}" >&2; exit 2; }
current="$(kubectl config current-context)"
[[ "${current}" == "${CONTEXT}" ]] || { echo "${R}current context is '${current}', not '${CONTEXT}'${N}" >&2; exit 2; }
k() { kubectl --context "${CONTEXT}" "$@"; }

if (( DELETE )); then
  echo "${B}Removing the demo from ${CONTEXT}${N}"
  files=("${STEPS}"/[0-9][0-9]-*.yaml)
  for (( i=${#files[@]}-1; i>=0; i-- )); do
    k delete -n "${NS}" -f "${files[i]}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  k -n "${NS}" delete kafka --all --ignore-not-found >/dev/null 2>&1 || true
  k -n "${NS}" delete pvc --all --ignore-not-found --wait=false || true
  k delete namespace "${NS}" tenant-a tenant-b tenant-c --ignore-not-found --wait=false || true
  echo "CRDs are left in place (other things may use them). To remove them too:"
  echo "  kubectl delete -f ${STEPS}/00-crds/"
  exit 0
fi

pause() { (( PAUSE )) && read -r -p "${Y}Enter to apply it…${N}" _ || true; }

if (( 10#${FROM} == 0 )); then
  echo; echo "${B}Step 00: CRDs (Gateway API, kgateway, Strimzi)${N}"
  echo "The object types the operators understand: Kafka, KafkaTopic, Gateway, HTTPRoute, …"
  pause
  k apply --server-side -f "${STEPS}/00-crds/" >/dev/null
  k wait --for=condition=Established crd/kafkas.kafka.strimzi.io crd/kafkabridges.kafka.strimzi.io \
    crd/gateways.gateway.networking.k8s.io crd/trafficpolicies.gateway.kgateway.dev --timeout=2m >/dev/null
  echo "${G}✓ CRDs established${N}"
fi

for f in "${STEPS}"/[0-9][0-9]-*.yaml; do
  n="$(basename "${f}" | cut -c1-2)"
  (( 10#${n} < 10#${FROM} )) && continue
  echo
  sed -n 's/^# \(Step .*\)$/'"${B}"'\1'"${N}"'/p; 2s/^# //p' "${f}" | head -2
  pause
  k apply -n "${NS}" -f "${f}" >/dev/null
  while read -r cmd; do
    echo "  waiting: ${cmd#kubectl }"
    # shellcheck disable=SC2086
    k ${cmd#kubectl } >/dev/null || { echo "${R}  not ready: ${cmd}${N}"; exit 1; }
  done < <(sed -n 's/^# wait: //p' "${f}")
  echo "${G}✓ step ${n} ready${N}"
done

cat <<MSG

${B}The demo is running.${N}

  The demonstrator:  kubectl -n ${NS} port-forward svc/log-flow-demonstrator 8080:8080   → http://localhost:8080
  Grafana:           kubectl -n ${NS} port-forward svc/grafana 3000:80                   → http://localhost:3000
                     admin / change-me-now (every tenant); tenant-a, tenant-b, tenant-c / change-me-now (their own)
MSG

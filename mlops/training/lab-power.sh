#!/usr/bin/env bash
# Switch the whole lab off for the night and on again, without losing anything.
#
#   lab-power.sh stop     scale the non-Kubeflow stacks to 0 (replica counts are saved),
#                         stop the port-forwards, shut the 3 VMs down gracefully
#   lab-power.sh start    start the VMs, wait for Kubeflow to be healthy FIRST, then
#                         bring the other stacks back, then the port-forwards
#
# VM disks are untouched: notebooks, models, repositories and data survive.
# DataHub is not touched either: if it was paused it stays paused.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
VIRSH=(virsh -c qemu:///system)
ok()   { printf '\033[1;32mOK  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR %s\033[0m\n' "$*" >&2; exit 1; }
SAVED="${LAB_ROOT}/.state/lab-power-replicas.tsv"
LATER_NS=(mlflow lakefs gitea argo jhub mr-alpha mr-beta)     # started after Kubeflow, in this order
KUBEFLOW_NS=(cert-manager istio-system auth oauth2-proxy knative-serving kubeflow-system kubeflow kubeflow-user-example-com)

wait_pods() {   # wait_pods <timeout seconds> <namespace>...  : no pod outside Running/Completed, all containers ready
  local deadline=$(( $(date +%s) + $1 )); shift
  while true; do
    local bad=0 ns
    for ns in "$@"; do
      bad=$(( bad + $(kubectl -n "${ns}" get pods --no-headers 2>/dev/null \
        | awk '$3!="Completed" { split($2,r,"/"); if ($3!="Running" || r[1]!=r[2]) n++ } END { print n+0 }') ))
    done
    [[ "${bad}" == 0 ]] && return 0
    (( $(date +%s) > deadline )) && { warn "${bad} pods still not ready in: $*"; return 1; }
    sleep 15
  done
}

stop() {
  : > "${SAVED}.new"
  for ns in "${LATER_NS[@]}"; do
    kubectl -n "${ns}" get deploy,sts --no-headers -o custom-columns=K:.kind,N:.metadata.name,R:.spec.replicas 2>/dev/null \
      | awk -v ns="${ns}" '$3>0 { print ns "\t" tolower($1) "\t" $2 "\t" $3 }' >> "${SAVED}.new"
  done
  # Keep an earlier save if this run finds nothing (stop called twice).
  [[ -s "${SAVED}.new" ]] && mv "${SAVED}.new" "${SAVED}" || rm -f "${SAVED}.new"
  while IFS=$'\t' read -r ns kind name _; do
    kubectl -n "${ns}" scale "${kind}/${name}" --replicas=0 >/dev/null
  done < "${SAVED}"
  log "Non-Kubeflow stacks scaled to 0 ($(wc -l < "${SAVED}") workloads, saved in ${SAVED})"
  "${MLOPS_ROOT}/training/lab.sh" down || true
  sleep 20                                    # let the pods end before the nodes go
  for vm in worker2 worker1 cp1; do "${VIRSH[@]}" shutdown "${vm}" >/dev/null 2>&1 || true; done
  local deadline=$(( $(date +%s) + 300 ))
  while [[ -n "$("${VIRSH[@]}" list --name --state-running | grep -E '^(cp1|worker1|worker2)$')" ]]; do
    (( $(date +%s) > deadline )) && die "VMs still running after 5 minutes: check 'virsh list'"
    sleep 5
  done
  ok "All three VMs are shut off. Start again with: mlops/training/lab-power.sh start"
}

start() {
  local t0; t0=$(date +%s)
  for vm in cp1 worker1 worker2; do
    [[ "$("${VIRSH[@]}" domstate "${vm}")" == running ]] || "${VIRSH[@]}" start "${vm}" >/dev/null
  done
  log "VMs started, waiting for the three nodes"
  local deadline=$(( $(date +%s) + 600 ))
  until [[ "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)" == 3 ]]; do
    (( $(date +%s) > deadline )) && die "Nodes not Ready after 10 minutes: kubectl get nodes"
    sleep 10
  done
  ok "3 nodes Ready after $(( $(date +%s) - t0 ))s"
  sleep 30                                    # pods of the old boot are still listed as Running for a moment
  log "Kubeflow first"
  wait_pods 1500 kube-system "${KUBEFLOW_NS[@]}" && ok "Kubeflow healthy after $(( $(date +%s) - t0 ))s"
  if [[ -s "${SAVED}" ]]; then
    log "Now the other stacks"
    while IFS=$'\t' read -r ns kind name replicas; do
      kubectl -n "${ns}" scale "${kind}/${name}" --replicas="${replicas}" >/dev/null
    done < "${SAVED}"
    wait_pods 900 "${LATER_NS[@]}" && { ok "Other stacks healthy after $(( $(date +%s) - t0 ))s"; rm -f "${SAVED}"; }
  fi
  "${MLOPS_ROOT}/training/lab.sh" up
}

case "${1:-}" in
  stop|start) "$1" ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

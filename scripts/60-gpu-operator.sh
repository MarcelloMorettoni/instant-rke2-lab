#!/usr/bin/env bash
# Install NVIDIA's GPU Operator and prove a pod can use the passed-through GPU.
# Needs the cluster (make all) built with GPU_PCI set. Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# `make all` calls this with --if-enabled: a lab without a GPU skips it quietly.
if [[ "${1:-}" == "--if-enabled" ]]; then
  [[ -n "${GPU_PCI}" ]] || exit 0
  shift
fi
[[ -n "${GPU_PCI}" ]] || die "GPU_PCI is empty in config.env — this lab has no GPU (see README 'GPU passthrough')"
KCONF="${STATE_DIR}/kubeconfig"
[[ -f "${KCONF}" ]] || die "kubeconfig missing — run 'make kubeconfig'"
export KUBECONFIG="${KCONF}"

# The GPU must actually be inside the VM, or the operator has nothing to find.
GPU_IP=""
for entry in "${VM_LIST[@]}"; do
  read -r name _ _ _ ip _ <<<"$entry"
  [[ "$name" == "${GPU_VM}" ]] && GPU_IP="$ip"
done
[[ -n "${GPU_IP}" ]] || die "GPU_VM=${GPU_VM} isn't in VM_LIST"
ssh_run "${GPU_IP}" "lspci -d 10de: | grep -q ." \
  || die "${GPU_VM} sees no NVIDIA device — was it created after 'make gpu-host'? (make destroy && make vms)"
log "${GPU_VM}: $(ssh_run "${GPU_IP}" "lspci -d 10de: | head -1")"

log "Installing NVIDIA GPU Operator ${GPU_OPERATOR_VERSION} (RKE2 HelmChart)"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION}" \
  envsubst '${GPU_OPERATOR_VERSION}' < "${LAB_ROOT}/manifests/gpu-operator.yaml" \
  | kubectl apply -f -

# The driver container compiles the kernel module on first start, and the
# toolkit restarts containerd (RKE2's agent restarts with it) — allow ~20 min.
log "Waiting for ${GPU_VM} to advertise nvidia.com/gpu (driver build takes several minutes)"
GPUS=""
for i in $(seq 1 120); do
  GPUS="$(kubectl get node "${GPU_VM}" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  [[ -n "${GPUS}" && "${GPUS}" != "0" ]] && break
  if (( i % 6 == 0 )); then
    kubectl -n gpu-operator get pods --no-headers 2>/dev/null \
      | awk '$3 != "Running" && $3 != "Completed" {printf "    %s %s\n", $1, $3}' >&2 || true
  fi
  sleep 10
done
[[ -n "${GPUS}" && "${GPUS}" != "0" ]] \
  || die "No nvidia.com/gpu on ${GPU_VM} after 20 min — kubectl -n gpu-operator get pods; check the nvidia-driver-daemonset logs"
ok "${GPU_VM}: nvidia.com/gpu = ${GPUS}"

log "Running a CUDA vector-add pod on the GPU"
kubectl delete pod gpu-smoke-test --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke-test
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: vectoradd
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
    resources:
      limits:
        nvidia.com/gpu: 1
YAML
for _ in $(seq 1 60); do
  PHASE="$(kubectl get pod gpu-smoke-test -o jsonpath='{.status.phase}')"
  [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]] && break
  sleep 5
done
kubectl logs gpu-smoke-test | tail -3 >&2 || true
kubectl delete pod gpu-smoke-test --ignore-not-found >/dev/null
[[ "${PHASE}" == "Succeeded" ]] || die "CUDA smoke test ended '${PHASE}'"
ok "GPU works in the cluster: request it with resources.limits nvidia.com/gpu: 1"

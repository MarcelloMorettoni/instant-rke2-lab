#!/usr/bin/env bash
# Shared settings for the MLOps evaluation lab (Kubeflow vs MLflow + Ray).
set -euo pipefail

MLOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${MLOPS_ROOT}/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${LAB_ROOT}/.state/kubeconfig}"

# Upstream sources are cloned here (gitignored), never vendored.
MLOPS_CACHE="${MLOPS_CACHE:-${MLOPS_ROOT}/.cache}"

# Pinned versions — what the evaluation was run with.
KUBEFLOW_MANIFESTS_VERSION="${KUBEFLOW_MANIFESTS_VERSION:-v1.11.0}"
# kubeflow/manifests is sensitive to the kustomize version: the 5.8.1 embedded
# in kubectl 1.36 leaves the default Profile as a literal "$(profile-name)".
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-v5.7.1}"
KUSTOMIZE="${MLOPS_CACHE}/bin/kustomize"

# The VM disks are thin qcow2 files on the host. Image pulls grow them, and a
# full host filesystem pauses the VMs, so refuse to continue below this.
HOST_MIN_FREE_GB="${HOST_MIN_FREE_GB:-12}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Follows symlinks: the disks may live on another filesystem than the repo.
host_free_gb() {
  local disk; disk="$(readlink -f "${LAB_ROOT}/vms/cp1/disk.qcow2" 2>/dev/null || true)"
  df -BG --output=avail "$(dirname "${disk:-${LAB_ROOT}/vms/x}")" | tail -1 | tr -dc '0-9'
}

check_host_disk() {
  local free; free="$(host_free_gb)"
  if (( free < HOST_MIN_FREE_GB )); then
    echo "host has ${free}G free where the VM disks live (< ${HOST_MIN_FREE_GB}G) — stopping" >&2
    return 1
  fi
  echo "host free space: ${free}G"
}

# Standalone kustomize at the version upstream pins, sha256-checked.
ensure_kustomize() {
  if [[ -x "${KUSTOMIZE}" ]] && "${KUSTOMIZE}" version | grep -qx "${KUSTOMIZE_VERSION}"; then return; fi
  local dl="${MLOPS_CACHE}/dl" tgz="kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
  local base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}"
  mkdir -p "${dl}" "${MLOPS_CACHE}/bin"
  ( cd "${dl}" && curl -fsSLO "${base}/${tgz}" && curl -fsSLO "${base}/checksums.txt" \
      && grep "${tgz}" checksums.txt | sha256sum -c - >/dev/null )
  tar -xzf "${dl}/${tgz}" -C "${MLOPS_CACHE}/bin" kustomize
}

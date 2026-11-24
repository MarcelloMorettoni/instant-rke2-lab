#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

BASE_IMG="${IMAGE_DIR}/${IMAGE_FILE}"
[[ -f "${BASE_IMG}" ]] || die "Base image missing — run 10-fetch-image.sh"
[[ -f "${SSH_KEY}.pub" ]] || die "SSH key missing — run 00-host-prep.sh"

PUBKEY="$(cat "${SSH_KEY}.pub")"

# GPU passthrough: the whole IOMMU group goes to GPU_VM, already on vfio-pci.
GPU_ARGS=()
if [[ -n "${GPU_PCI}" ]]; then
  mapfile -t GPU_DEVS < <(gpu_group_devices)
  (( ${#GPU_DEVS[@]} > 0 )) || die "GPU_PCI=${GPU_PCI}: no passthrough devices found — run 'make gpu-host' first"
  for dev in "${GPU_DEVS[@]}"; do
    [[ "$(pci_driver "${dev}")" == "vfio-pci" ]] \
      || die "${dev} is on '$(pci_driver "${dev}")', not vfio-pci — run 'make gpu-host' first"
    GPU_ARGS+=(--host-device "${dev}")
  done
  log "GPU passthrough: ${GPU_DEVS[*]} → ${GPU_VM}"
fi

create_vm() {
  local name=$1 vcpus=$2 mem=$3 disk_gb=$4 ip=$5
  local vm_dir="${VM_DIR}/${name}"
  local disk="${vm_dir}/disk.qcow2"
  local seed="${vm_dir}/seed.iso"
  local user_data="${vm_dir}/user-data"
  local meta_data="${vm_dir}/meta-data"
  local net_config="${vm_dir}/network-config"

  if VIRSH dominfo "${name}" >/dev/null 2>&1; then
    warn "VM ${name} already defined — skipping (use 99-destroy.sh to reset)"
    return 0
  fi

  log "Creating ${name}: ${vcpus} vCPU / ${mem} MiB / ${disk_gb} G / ${ip}"
  mkdir -p "${vm_dir}"

  # Backed qcow2 — small, fast, references the immutable base image
  qemu-img create -q -F qcow2 -b "${BASE_IMG}" -f qcow2 "${disk}" "${disk_gb}G"

  cat > "${meta_data}" <<EOF
instance-id: ${name}
local-hostname: ${name}
EOF

  cat > "${user_data}" <<EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: ${SSH_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${PUBKEY}
package_update: true
packages:
  - curl
  - jq
  - iproute2
  - apparmor-utils
  - pciutils
write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      br_netfilter
      overlay
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
      # Many watchers (GPU Operator validators, Kubeflow): RKE2's recommended
      # minimum, and Kubeflow's watch count.
      fs.inotify.max_user_instances = 8192
      fs.inotify.max_user_watches = 1255360
runcmd:
  - swapoff -a
  - sed -i.bak '/\sswap\s/ s/^/#/' /etc/fstab
  - modprobe br_netfilter
  - modprobe overlay
  - sysctl --system
EOF

  cat > "${net_config}" <<EOF
version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: false
    addresses: [${ip}/24]
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses: [${NET_DNS_PRIMARY}, ${NET_DNS_SECONDARY}]
EOF

  cloud-localds -N "${net_config}" "${seed}" "${user_data}" "${meta_data}"

  # PCIe passthrough wants a q35 machine; only the GPU VM gets the devices.
  local extra=()
  if [[ "${name}" == "${GPU_VM}" && ${#GPU_ARGS[@]} -gt 0 ]]; then
    extra=(--machine q35 "${GPU_ARGS[@]}")
  fi

  VIRT_INSTALL \
    --connect qemu:///system \
    --name "${name}" \
    --memory "${mem}" \
    --vcpus "${vcpus}" \
    --cpu host-passthrough \
    --disk "path=${disk},format=qcow2,bus=virtio,cache=none" \
    --disk "path=${seed},device=cdrom" \
    --os-variant ubuntu22.04 \
    --network "network=${LIBVIRT_NETWORK},model=virtio" \
    --graphics none \
    --noautoconsole \
    --import \
    "${extra[@]}" \
    --quiet
}

if [[ -n "${GPU_PCI}" ]]; then
  printf '%s\n' "${VM_LIST[@]}" | awk '{print $1}' | grep -qx "${GPU_VM}" \
    || die "GPU_VM=${GPU_VM} isn't in VM_LIST"
fi

for entry in "${VM_LIST[@]}"; do
  read -r name vcpus mem disk ip role <<<"$entry"
  create_vm "$name" "$vcpus" "$mem" "$disk" "$ip"
done

log "Waiting for SSH on each VM (cloud-init can take a minute or two)…"
for entry in "${VM_LIST[@]}"; do
  read -r name vcpus mem disk ip role <<<"$entry"
  log "  ${name} — ${ip}"
  wait_for_ssh "$ip" 600
  ok "  ${name} reachable"
done

ok "All VMs running"
VIRSH list

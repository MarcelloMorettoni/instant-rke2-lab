#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

BASE_IMG="${IMAGE_DIR}/${IMAGE_FILE}"
[[ -f "${BASE_IMG}" ]] || die "Base image missing — run 10-fetch-image.sh"
[[ -f "${SSH_KEY}.pub" ]] || die "SSH key missing — run 00-host-prep.sh"

PUBKEY="$(cat "${SSH_KEY}.pub")"

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
    --quiet
}

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

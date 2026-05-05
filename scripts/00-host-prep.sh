#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

log "Host pre-flight"

[[ -e /dev/kvm ]] || die "/dev/kvm missing — enable virtualization in BIOS"
grep -qE '(vmx|svm)' /proc/cpuinfo || die "No CPU virt extensions (vmx/svm)"

PKGS=(
  qemu-kvm libvirt-daemon-system libvirt-clients
  bridge-utils virtinst cloud-image-utils genisoimage
  curl jq gettext-base ca-certificates gnupg
)

log "Installing virtualization packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"

if ! command -v kubectl >/dev/null 2>&1; then
  K8S_REPO="${KUBECTL_REPO_CHANNEL:-v1.35}"
  log "Installing kubectl from pkgs.k8s.io/${K8S_REPO}"
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO}/deb/Release.key" \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq kubectl
fi

ME="$(id -un)"
NEED_RELOGIN=0
for grp in kvm libvirt; do
  if ! id -nG "$ME" | tr ' ' '\n' | grep -qx "$grp"; then
    log "Adding ${ME} to group ${grp}"
    sudo usermod -aG "$grp" "$ME"
    NEED_RELOGIN=1
  fi
done

log "Enabling libvirtd"
sudo systemctl enable --now libvirtd
sudo systemctl enable --now virtlogd 2>/dev/null || true

log "virt-host-validate (warnings are usually fine for a lab)"
sudo virt-host-validate qemu | grep -E 'PASS|WARN|FAIL' || true

# Default NAT network (virbr0)
if sudo virsh net-info default >/dev/null 2>&1; then
  if [[ "$(sudo virsh net-info default | awk '/^Active:/ {print $2}')" != "yes" ]]; then
    sudo virsh net-start default
  fi
  sudo virsh net-autostart default >/dev/null
else
  warn "Default libvirt network not present — creating it"
  sudo virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null \
    || warn "Couldn't define default net automatically — install libvirt-daemon-config-network"
  sudo virsh net-start default
  sudo virsh net-autostart default
fi

# Storage pool on /data
mkdir -p "${VM_DIR}" "${IMAGE_DIR}" "${STATE_DIR}"
chmod 755 "${VM_DIR}"
if ! sudo virsh pool-info "${POOL_NAME}" >/dev/null 2>&1; then
  log "Creating libvirt storage pool '${POOL_NAME}' at ${VM_DIR}"
  sudo virsh pool-define-as "${POOL_NAME}" dir --target "${VM_DIR}" >/dev/null
  sudo virsh pool-build "${POOL_NAME}" >/dev/null
  sudo virsh pool-start "${POOL_NAME}" >/dev/null
  sudo virsh pool-autostart "${POOL_NAME}" >/dev/null
else
  if [[ "$(sudo virsh pool-info "${POOL_NAME}" | awk '/^State:/ {print $2}')" != "running" ]]; then
    sudo virsh pool-start "${POOL_NAME}"
  fi
fi

# SSH key for the lab
if [[ ! -f "${SSH_KEY}" ]]; then
  log "Generating SSH keypair at ${SSH_KEY}"
  ssh-keygen -t ed25519 -N '' -f "${SSH_KEY}" -C "slinky-lab" >/dev/null
fi
chmod 600 "${SSH_KEY}"

ok "Host prep complete"
if (( NEED_RELOGIN )); then
  warn "User added to kvm/libvirt groups. Logout/login (or 'newgrp libvirt') to use virsh without sudo."
  warn "Scripts will fall back to sudo until then — that's fine."
fi

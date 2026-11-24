#!/usr/bin/env bash
# Prepare the host to pass GPU_PCI through to a VM. Run before `make vms`.
#
#   1. IOMMU on (kernel command line; needs VT-d / AMD-Vi enabled in the BIOS)
#   2. The GPU's IOMMU group holds only the GPU's own functions
#   3. Every function in the group bound to vfio-pci, persistently (driverctl)
#
#   15-gpu-host.sh --undo   give the GPU back to the host's own driver
#
# Idempotent. Step 1 may ask for a reboot; re-run afterwards.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# `make all` calls this with --if-enabled: a lab without a GPU skips it quietly.
if [[ "${1:-}" == "--if-enabled" ]]; then
  [[ -n "${GPU_PCI}" ]] || exit 0
  shift
fi
[[ -n "${GPU_PCI}" ]] || die "GPU_PCI is empty in config.env — set it to the GPU's address from 'lspci | grep -i nvidia'"
GPU="$(gpu_pci_full)"
GRUB_DROPIN=/etc/default/grub.d/90-instant-rke2-lab-iommu.cfg

###############################################################################
# --undo
###############################################################################
if [[ "${1:-}" == "--undo" ]]; then
  command -v driverctl >/dev/null || die "driverctl not installed — nothing to undo"
  VIRSH dominfo "${GPU_VM}" >/dev/null 2>&1 && die "${GPU_VM} still exists and owns the GPU — run 'make destroy' first"
  for dev in $(sudo driverctl list-overrides | awk -v g="${GPU%.*}" 'index($1, g) == 1 {print $1}'); do
    log "Releasing ${dev} from vfio-pci"
    sudo driverctl unset-override "${dev}"
  done
  if [[ -f "${GRUB_DROPIN}" ]]; then
    log "Removing ${GRUB_DROPIN} (IOMMU kernel flags)"
    sudo rm -f "${GRUB_DROPIN}"
    sudo update-grub
    warn "Reboot to drop the IOMMU kernel flags (optional — they're harmless)."
  fi
  ok "GPU ${GPU} returned to the host"
  exit 0
fi

log "GPU passthrough host prep for ${GPU} → VM ${GPU_VM}"
[[ -e "/sys/bus/pci/devices/${GPU}" ]] || die "No PCI device ${GPU}. Check GPU_PCI against 'lspci -nn | grep -iE \"vga|3d\"'"

VENDOR="$(cat "/sys/bus/pci/devices/${GPU}/vendor")"
[[ "${VENDOR}" == "0x10de" ]] \
  || warn "${GPU} isn't an NVIDIA device (vendor ${VENDOR}); 'make gpu' only sets up NVIDIA's GPU Operator"
log "  $(lspci -s "${GPU}")"

###############################################################################
# 1. IOMMU
###############################################################################
if [[ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
  if grep -q GenuineIntel /proc/cpuinfo; then FLAGS="intel_iommu=on iommu=pt"; else FLAGS="amd_iommu=on iommu=pt"; fi
  if [[ -f "${GRUB_DROPIN}" ]] && grep -q "${FLAGS}" /proc/cmdline; then
    die "Kernel has '${FLAGS}' but no IOMMU groups — enable VT-d (Intel) / AMD-Vi or IOMMU in the BIOS"
  fi
  log "IOMMU is off. Adding '${FLAGS}' to the kernel command line via ${GRUB_DROPIN}"
  sudo install -d /etc/default/grub.d
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} %s"\n' "${FLAGS}" \
    | sudo tee "${GRUB_DROPIN}" >/dev/null
  sudo update-grub
  warn "Reboot the host, then run 'make gpu-host' again."
  warn "If IOMMU is still off after the reboot, enable VT-d / AMD-Vi in the BIOS."
  exit 2
fi
ok "IOMMU enabled ($(ls /sys/kernel/iommu_groups | wc -l) groups)"

###############################################################################
# 2. IOMMU group must contain only this GPU's functions
###############################################################################
mapfile -t DEVS < <(gpu_group_devices)
(( ${#DEVS[@]} > 0 )) || die "No devices found in ${GPU}'s IOMMU group"
SLOT="${GPU%.*}"                          # 0000:01:00 — all functions of the card
for dev in "${DEVS[@]}"; do
  if [[ "${dev%.*}" != "${SLOT}" ]]; then
    err "IOMMU group $(basename "$(readlink -f "/sys/bus/pci/devices/${GPU}/iommu_group")") also holds a device that isn't part of the GPU:"
    for d in "${DEVS[@]}"; do lspci -s "$d" >&2; done
    die "Passing these through would take them from the host too. Try another PCIe slot, or a BIOS ACS option."
  fi
done
ok "IOMMU group: ${DEVS[*]}"

# Don't take the GPU away from the host's console.
if [[ "$(cat "/sys/bus/pci/devices/${GPU}/boot_vga" 2>/dev/null || echo 0)" == "1" ]]; then
  warn "${GPU} is the host's boot display GPU. Passing it through blanks the host console;"
  warn "use SSH. Set FORCE=1 to continue."
  [[ "${FORCE:-}" == "1" ]] || exit 1
fi

###############################################################################
# 3. Bind to vfio-pci (persistent across reboots)
###############################################################################
if ! command -v driverctl >/dev/null; then
  log "Installing driverctl"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq driverctl
fi
sudo modprobe vfio-pci

for dev in "${DEVS[@]}"; do
  drv="$(pci_driver "${dev}")"
  if [[ "${drv}" == "vfio-pci" ]]; then
    ok "  ${dev}: already on vfio-pci"
    continue
  fi
  if [[ "${drv}" == "nvidia" ]]; then
    # A running nvidia-persistenced (or a desktop) keeps the device busy.
    sudo systemctl stop nvidia-persistenced 2>/dev/null || true
  fi
  log "  ${dev}: ${drv} → vfio-pci"
  sudo driverctl set-override "${dev}" vfio-pci
  [[ "$(pci_driver "${dev}")" == "vfio-pci" ]] \
    || die "${dev} didn't bind to vfio-pci (in use by the host?). Stop what uses it, or reboot and re-run"
done

ok "GPU ready for passthrough. Next: 'make vms' (${GPU_VM} gets ${DEVS[*]}), then 'make cluster' and 'make gpu'."

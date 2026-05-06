#!/usr/bin/env bash
# Shared helpers. Source me, don't run me.
# shellcheck disable=SC2034,SC1091

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

log()  { printf '%s[slinky]%s %s\n' "$BLUE"   "$NC" "$*" >&2; }
ok()   { printf '%s[slinky]%s %s\n' "$GREEN"  "$NC" "$*" >&2; }
warn() { printf '%s[slinky]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s[slinky]%s %s\n' "$RED"    "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Locate repo root and load config
__LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT_DETECTED="$(cd "${__LIB_DIR}/.." && pwd)"
source "${LAB_ROOT_DETECTED}/config.env"

# Use sudo for libvirt iff user isn't in the libvirt group yet
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx libvirt; then
  LIBVIRT_SUDO=""
else
  LIBVIRT_SUDO="sudo"
fi

VIRSH()        { ${LIBVIRT_SUDO} virsh "$@"; }
VIRT_INSTALL() { ${LIBVIRT_SUDO} virt-install "$@"; }

ssh_opts=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o LogLevel=ERROR
)

ssh_run() {
  local host=$1; shift
  ssh -T "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
}

scp_to() {
  local src=$1 host=$2 dst=$3
  scp "${ssh_opts[@]}" "$src" "${SSH_USER}@${host}:${dst}"
}

scp_from() {
  local host=$1 src=$2 dst=$3
  scp "${ssh_opts[@]}" "${SSH_USER}@${host}:${src}" "$dst"
}

wait_for_ssh() {
  local host=$1
  local timeout=${2:-300}
  local start=$SECONDS
  while ! ssh_run "$host" true 2>/dev/null; do
    (( SECONDS - start > timeout )) && die "Timeout waiting for SSH on ${host}"
    sleep 3
  done
}

# Iterate VM_LIST and split fields. Usage:
#   for_each_vm name vcpus mem disk ip role -- 'echo $name $ip'
# Easier: just `read -r name vcpus mem disk ip role <<<"$entry"` in callers.

control_plane_ip() {
  local name vcpus mem disk ip role
  for entry in "${VM_LIST[@]}"; do
    read -r name vcpus mem disk ip role <<<"$entry"
    [[ "$role" == "server" ]] && { echo "$ip"; return 0; }
  done
  return 1
}

control_plane_name() {
  local name vcpus mem disk ip role
  for entry in "${VM_LIST[@]}"; do
    read -r name vcpus mem disk ip role <<<"$entry"
    [[ "$role" == "server" ]] && { echo "$name"; return 0; }
  done
  return 1
}

host_lan_ip() {
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 \
    | grep -v '^192\.168\.122\.' | head -1
}

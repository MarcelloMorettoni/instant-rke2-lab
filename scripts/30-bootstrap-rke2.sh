#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CP_NAME="$(control_plane_name)"
CP_IP="$(control_plane_ip)"
[[ -n "$CP_IP" ]] || die "No 'server' role in VM_LIST"

declare -a AGENT_NAMES=() AGENT_IPS=()
for entry in "${VM_LIST[@]}"; do
  read -r name vcpus mem disk ip role <<<"$entry"
  if [[ "$role" == "agent" ]]; then
    AGENT_NAMES+=("$name"); AGENT_IPS+=("$ip")
  fi
done

HOST_IP="$(host_lan_ip)"
log "Control plane: ${CP_NAME} @ ${CP_IP}"
log "Agents:        ${AGENT_NAMES[*]}"
log "Host LAN IP:   ${HOST_IP:-<unknown>}"

RKE2_ENV="INSTALL_RKE2_CHANNEL=${RKE2_CHANNEL}"
[[ -n "${RKE2_VERSION}" ]] && RKE2_ENV+=" INSTALL_RKE2_VERSION=${RKE2_VERSION}"

###############################################################################
# Control plane
###############################################################################
log "Writing /etc/rancher/rke2/config.yaml on ${CP_NAME}"
ssh_run "${CP_IP}" "sudo mkdir -p /etc/rancher/rke2 /var/lib/rancher/rke2/server/manifests"
ssh_run "${CP_IP}" "sudo tee /etc/rancher/rke2/config.yaml >/dev/null" <<YAML
write-kubeconfig-mode: "0644"
tls-san:
  - ${CP_IP}
$( [[ -n "${HOST_IP}" ]] && echo "  - ${HOST_IP}" )
  - ${CP_NAME}
cni: cilium
disable-kube-proxy: true
cluster-cidr: ${CLUSTER_CIDR}
service-cidr: ${SERVICE_CIDR}
node-ip: ${CP_IP}
YAML

log "Installing Cilium HelmChartConfig"
# Render manifest with envsubst-style substitution from this shell
CILIUM_TPL="${SLINKY_ROOT}/manifests/rke2-cilium-config.yaml"
[[ -f "${CILIUM_TPL}" ]] || die "Missing manifest template: ${CILIUM_TPL}"
RENDERED="$(CP_IP="${CP_IP}" CILIUM_HUBBLE_UI="${CILIUM_HUBBLE_UI}" \
  envsubst '${CP_IP} ${CILIUM_HUBBLE_UI}' < "${CILIUM_TPL}")"
ssh_run "${CP_IP}" "sudo tee /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml >/dev/null" <<<"${RENDERED}"

log "Running RKE2 server installer on ${CP_NAME} (this downloads ~250 MB)"
ssh_run "${CP_IP}" "curl -sfL https://get.rke2.io | sudo ${RKE2_ENV} sh -"

log "Enabling and starting rke2-server.service"
ssh_run "${CP_IP}" "sudo systemctl enable --now rke2-server.service"

log "Waiting for kubeconfig and node-token on ${CP_NAME}"
for _ in $(seq 1 90); do
  if ssh_run "${CP_IP}" "sudo test -s /etc/rancher/rke2/rke2.yaml && sudo test -s /var/lib/rancher/rke2/server/node-token"; then
    break
  fi
  sleep 5
done
ssh_run "${CP_IP}" "sudo test -s /etc/rancher/rke2/rke2.yaml" \
  || die "rke2-server didn't produce kubeconfig in time — check 'journalctl -u rke2-server' on ${CP_NAME}"

TOKEN="$(ssh_run "${CP_IP}" 'sudo cat /var/lib/rancher/rke2/server/node-token')"
[[ -n "$TOKEN" ]] || die "Failed to read node-token"
printf '%s\n' "${TOKEN}" > "${STATE_DIR}/node-token"
chmod 600 "${STATE_DIR}/node-token"

log "Waiting for ${CP_NAME} to be Ready"
KCMD='sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig=/etc/rancher/rke2/rke2.yaml'
for _ in $(seq 1 90); do
  STATE="$(ssh_run "${CP_IP}" "${KCMD} get node ${CP_NAME} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || true)"
  [[ "${STATE}" == "True" ]] && break
  sleep 5
done
[[ "${STATE:-}" == "True" ]] || warn "${CP_NAME} not Ready yet — agents will still try to join"

ok "Control-plane up"

###############################################################################
# Agents
###############################################################################
for i in "${!AGENT_NAMES[@]}"; do
  AG_NAME="${AGENT_NAMES[$i]}"
  AG_IP="${AGENT_IPS[$i]}"
  log "Configuring agent ${AG_NAME} @ ${AG_IP}"

  ssh_run "${AG_IP}" "sudo mkdir -p /etc/rancher/rke2"
  ssh_run "${AG_IP}" "sudo tee /etc/rancher/rke2/config.yaml >/dev/null" <<YAML
server: https://${CP_IP}:9345
token: ${TOKEN}
node-ip: ${AG_IP}
YAML

  log "Running RKE2 agent installer on ${AG_NAME}"
  ssh_run "${AG_IP}" "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=agent ${RKE2_ENV} sh -"
  ssh_run "${AG_IP}" "sudo systemctl enable --now rke2-agent.service"
  ok "Agent ${AG_NAME} install kicked off"
done

log "Waiting for all agents to register and become Ready"
for AG in "${AGENT_NAMES[@]}"; do
  STATE=""
  for _ in $(seq 1 120); do
    STATE="$(ssh_run "${CP_IP}" "${KCMD} get node ${AG} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || true)"
    [[ "${STATE}" == "True" ]] && break
    sleep 5
  done
  if [[ "${STATE}" == "True" ]]; then
    ok "  ${AG} Ready"
  else
    warn "  ${AG} not Ready yet — check 'journalctl -u rke2-agent' on the node"
  fi
done

ok "Cluster bootstrap finished"
ssh_run "${CP_IP}" "${KCMD} get nodes -o wide" || true

#!/usr/bin/env bash
# Install the Slinky stack (cert-manager, slurm-operator, slurm cluster) on the
# instant-rke2-lab cluster. Idempotent — safe to re-run after edits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { printf '%s[slinky]%s %s\n' "$BLUE"   "$NC" "$*" >&2; }
ok()   { printf '%s[slinky]%s %s\n' "$GREEN"  "$NC" "$*" >&2; }
warn() { printf '%s[slinky]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s[slinky]%s %s\n' "$RED"    "$NC" "$*" >&2; exit 1; }

export KUBECONFIG="${KUBECONFIG:-${LAB_ROOT}/.state/kubeconfig}"
[[ -f "$KUBECONFIG" ]] || die "kubeconfig not found at $KUBECONFIG — run 'make all' from the lab root first"

command -v kubectl >/dev/null || die "kubectl not installed — run 'make prereqs' in the lab root"

###############################################################################
# helm
###############################################################################
if ! command -v helm >/dev/null 2>&1; then
  log "Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

###############################################################################
# Storage class — RKE2 ships without a default provisioner
###############################################################################
if ! kubectl get sc 2>/dev/null | awk '{print $2}' | grep -q '(default)'; then
  log "Installing local-path-provisioner (Rancher) and marking it default"
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl wait --for=condition=Available --timeout=120s -n local-path-storage deploy/local-path-provisioner
  kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class=true --overwrite
else
  ok "Default storage class already present"
fi

###############################################################################
# cert-manager (prereq for the slurm-operator's webhook certs)
###############################################################################
if ! kubectl get ns cert-manager >/dev/null 2>&1; then
  log "Installing cert-manager"
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm repo update jetstack >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 5m
else
  ok "cert-manager namespace already present"
fi

###############################################################################
# slurm-operator-crds + slurm-operator
###############################################################################
log "Installing slurm-operator-crds"
helm upgrade --install slurm-operator-crds \
  oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --wait --timeout 5m

log "Installing slurm-operator (namespace: slinky)"
helm upgrade --install slurm-operator \
  oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace slinky --create-namespace \
  -f "${SCRIPT_DIR}/values/slurm-operator.yaml" \
  --wait --timeout 5m

###############################################################################
# slurm cluster
###############################################################################
log "Installing slurm cluster (namespace: slurm) — this pulls slurmctld/slurmd images, can take ~5 min"
helm upgrade --install slurm \
  oci://ghcr.io/slinkyproject/charts/slurm \
  --namespace slurm --create-namespace \
  -f "${SCRIPT_DIR}/values/slurm.yaml" \
  --wait --timeout 10m

ok "Slinky stack installed"
echo
log "Pods:"
kubectl -n slinky get pods
kubectl -n slurm  get pods
echo
log "Login pod is your sbatch entrypoint:"
echo "    ./scripts/login.sh"
echo "    ./scripts/submit.sh examples/01-hello.sbatch"
echo "    ./scripts/status.sh"

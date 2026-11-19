#!/usr/bin/env bash
# Optional: host tools for the add-on labs (soft-tenancy/, slinky/, generic/).
# Not part of `make all` — the raw cluster doesn't need any of this.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

log "Installing tools for the optional labs"

if ! command -v jq >/dev/null 2>&1; then
  log "Installing jq"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
fi

# helm: not in Ubuntu's archive. Pinned release tarball from get.helm.sh,
# checked against its sha256.
if ! command -v helm >/dev/null 2>&1; then
  HV="${HELM_VERSION:-v3.22.1}"
  ARCH="$(dpkg --print-architecture)"
  TARBALL="helm-${HV}-linux-${ARCH}.tar.gz"
  log "Installing helm ${HV} (${ARCH}) to /usr/local/bin"
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  curl -fsSL -o "${TMP}/${TARBALL}" "https://get.helm.sh/${TARBALL}"
  curl -fsSL -o "${TMP}/${TARBALL}.sha256sum" "https://get.helm.sh/${TARBALL}.sha256sum"
  (cd "${TMP}" && sha256sum -c --quiet "${TARBALL}.sha256sum") \
    || die "helm checksum mismatch for ${TARBALL}"
  tar -xzf "${TMP}/${TARBALL}" -C "${TMP}"
  sudo install -m 0755 "${TMP}/linux-${ARCH}/helm" /usr/local/bin/helm
fi

ok "Extras ready: $(helm version --short), $(jq --version)"

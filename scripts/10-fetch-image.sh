#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

mkdir -p "${IMAGE_DIR}"
DEST="${IMAGE_DIR}/${IMAGE_FILE}"

if [[ -f "${DEST}" && -s "${DEST}" ]]; then
  ok "Image already present: ${DEST}"
  exit 0
fi

log "Downloading ${IMAGE_URL}"
curl -fL --progress-bar -o "${DEST}.part" "${IMAGE_URL}"
mv "${DEST}.part" "${DEST}"
ok "Image saved: ${DEST}"

#!/usr/bin/env bash
# Render every diagrams/*.svg to a 2x PNG (for Confluence / Word), with headless Chrome.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-$(command -v google-chrome || command -v chromium || command -v chromium-browser)}"
[[ -n "${CHROME}" ]] || { echo "need google-chrome or chromium" >&2; exit 1; }
# Work files and Chrome's profile stay under the repo (.cache), never in /tmp.
mkdir -p "${DIR}/../.cache"
tmp="$(mktemp -d -p "$(cd "${DIR}/../.cache" && pwd)")"; trap 'rm -rf "${tmp}"' EXIT
for svg in "${DIR}"/*.svg; do
  read -r w h < <(sed -n 's/.*<svg[^>]* width="\([0-9]*\)" height="\([0-9]*\)".*/\1 \2/p' "${svg}" | head -1)
  html="${tmp}/$(basename "${svg}" .svg).html"
  printf '<html><body style="margin:0">%s</body></html>' "$(cat "${svg}")" > "${html}"
  "${CHROME}" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --user-data-dir="${tmp}/chrome" \
    --window-size="${w},${h}" --screenshot="${svg%.svg}.png" "file://${html}" >/dev/null 2>&1
  echo "${svg%.svg}.png"
done

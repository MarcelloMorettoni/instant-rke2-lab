#!/usr/bin/env bash
# The platform as plain Kubernetes YAML, one file per component, for review:
#
#   scripts/render-manifests.sh [env...]        (default: azure generic)
#
# Writes manifests/<env>/{operators,platform}/NN-<component>.yaml and
# manifests/<env>/README.md. Exactly what install.sh would apply (same values,
# overlays and order), except:
#   - Secret data is REDACTED (generated values, certificates, copies);
#   - CRDs are listed in README.md, not copied (they come from the charts);
#   - Secrets the chart copies at install time (Percona users) are absent:
#     `helm template` can't look them up.
# The charts stay the way to install; these files are for reading and diffing.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm python3
ENVS=("$@"); [[ ${#ENVS[@]} -gt 0 ]] || ENVS=(azure generic)
cd "${GEN_DIR}"
python3 scripts/render-tenants.py >/dev/null
for e in "${ENVS[@]}"; do
  load_env "${e}"
  python3 scripts/render-images.py "${e}" >/dev/null
  tmp="$(mktemp -d)"
  helm template log-platform-operators charts/log-platform-operators -n platform-operators \
    "${ENV_VALUES[@]}" > "${tmp}/operators.yaml"
  helm template log-platform charts/log-platform -n loki --kube-version 1.33.0 \
    "${PLATFORM_VALUES[@]}" > "${tmp}/platform.yaml"
  python3 scripts/split-manifests.py --env "${e}" --overlays "${ENV_DIR}/overlays.txt" \
    --out "manifests/${e}" "${tmp}/operators.yaml" "${tmp}/platform.yaml"
  rm -rf "${tmp}"
done

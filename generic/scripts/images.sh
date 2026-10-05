#!/usr/bin/env bash
# Every container image the platform will pull in environment <env>, as the
# nodes will request it. Give this list to whoever runs the registry proxy.
#
#   scripts/images.sh <env>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm python3
ENV="${1:?usage: images.sh <env>}"
E="${GEN_DIR}/environments/${ENV}"
cd "${GEN_DIR}"
python3 scripts/render-tenants.py >/dev/null
python3 scripts/render-images.py "${ENV}" >/dev/null
{
  helm template log-platform-operators charts/log-platform-operators -n platform-operators \
    -f "${E}/values.yaml" -f "${E}/generated-images.yaml"
  helm template log-platform charts/log-platform -n loki \
    -f rendered/values-tenants.yaml -f "${E}/values.yaml" -f "${E}/generated-images.yaml"
} > "${TMPDIR}/images.yaml"
{
  grep -oE '(image|value): *"?[a-z0-9.:/_-]+/[a-z0-9._/-]+:[A-Za-z0-9._-]+' "${TMPDIR}/images.yaml" \
    | sed -E 's/^(image|value): *"?//' | grep -v '^http'
  # Kafka brokers: Strimzi's image map, for the version the Kafka CR asks for.
  v="$(awk '/^kind: Kafka$/{k=1} k && /^    version:/{gsub(/"/,"",$2); print $2; exit}' "${TMPDIR}/images.yaml")"
  [[ -n "${v}" ]] && grep -oE "^ +${v}=[^ ]+" "${TMPDIR}/images.yaml" | head -1 | sed -E 's/^ +[0-9.]+=//'
} | grep -vE 'buildah|kaniko|maven-builder|kafka-bridge|drain-cleaner' | sort -u
# Created at runtime by kgateway (one proxy per Gateway), not by Helm:
REG="$(python3 -c "import yaml,sys; print(((yaml.safe_load(open(sys.argv[1])) or {}).get('global') or {}).get('imageRegistry') or 'cr.kgateway.dev')" "${E}/values.yaml")"
[[ "${REG}" == cr.kgateway.dev ]] && echo "cr.kgateway.dev/kgateway-dev/envoy-wrapper:${KGATEWAY_VERSION}" \
  || echo "${REG%/}/kgateway-dev/envoy-wrapper:${KGATEWAY_VERSION}"

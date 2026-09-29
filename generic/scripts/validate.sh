#!/usr/bin/env bash
# Offline validation of the charts as they will be installed. No cluster, no Azure.
# Needs helm, python3 and docker; terraform when present.
#
#   scripts/validate.sh [env]        (default: example)
#
#   1. tenants.yaml valid; rendered/ and generated-images.yaml up to date
#   2. both charts render: the environment, and the test-cluster overlay
#   3. the Loki config the chart produces, and every tenant's limits, load in Loki
#   4. both OTel collector configs the chart produces load in the collector
#   5. every custom resource matches its CRD schema (unknown fields = error)
#   6. alert rules pass promtool
#   7. terraform validate + a mocked plan (terraform test)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm python3 docker
load_env "${1:-example}"
cd "${GEN_DIR}"
OUT="${CACHE_DIR}/out"; rm -rf "${OUT}"; mkdir -p "${OUT}" "${CACHE_DIR}/crds"

log "1/7 tenant registry, images"
python3 scripts/render-tenants.py --check
python3 scripts/render-tenants.py >/dev/null
python3 scripts/render-images.py "${ENV_NAME}" >/dev/null

log "2/7 helm template (environment ${ENV_NAME}, and + overlays/test-cluster.yaml)"
for c in log-platform-operators log-platform; do
  [[ -d "charts/${c}/charts" ]] || helm dependency build "charts/${c}" >/dev/null
done
helm template log-platform-operators charts/log-platform-operators -n kgateway-system \
  "${ENV_VALUES[@]}" > "${OUT}/operators.yaml"
helm template log-platform charts/log-platform -n loki --kube-version 1.33.0 \
  "${ENV_VALUES[@]}" -f rendered/values-tenants.yaml > "${OUT}/platform.yaml"
helm template log-platform charts/log-platform -n loki --kube-version 1.33.0 \
  "${ENV_VALUES[@]}" -f environments/overlays/test-cluster.yaml -f rendered/values-tenants.yaml > "${OUT}/platform-test.yaml"
ok "charts render ($(grep -c '^kind:' "${OUT}/platform.yaml") platform objects)"

log "3/7 Loki config and per-tenant limits in ${LOKI_IMAGE}"
python3 - "${OUT}" <<'PY'
import sys, yaml, pathlib
out = pathlib.Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all((out / "platform.yaml").read_text()) if d]
cm = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ConfigMap" and d["metadata"].get("namespace") == "loki"}
cfg = yaml.safe_load(cm["loki"]["data"]["config.yaml"])
runtime = yaml.safe_load(cm["loki-runtime"]["data"]["runtime-config.yaml"])
cfg["runtime_config"] = {"file": ""}
(out / "loki-config.yaml").write_text(yaml.safe_dump(cfg))
for tenant, limits in (runtime.get("overrides") or {}).items():
    c = dict(cfg); c["limits_config"] = {**cfg["limits_config"], **limits}
    (out / f"loki-config-{tenant}.yaml").write_text(yaml.safe_dump(c))
for name, key in (("otel-agent-agent", "agent"), ("otel-gateway-statefulset", "gateway")):
    d = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == name)
    (out / f"otel-{key}-config.yaml").write_text(d["data"]["relay"])
PY
for f in "${OUT}"/loki-config*.yaml; do
  docker run --rm -v "${OUT}:/cfg:ro" "${LOKI_IMAGE}" -config.file="/cfg/$(basename "$f")" -verify-config >/dev/null 2>"${OUT}/err" \
    || { cat "${OUT}/err"; die "Loki rejects $(basename "$f")"; }
done
ok "Loki accepts the chart's config and every tenant's limits"

log "4/7 OpenTelemetry collector configs in ${OTELCOL_IMAGE}"
for c in agent gateway; do
  docker run --rm -e MY_POD_IP=127.0.0.1 -e K8S_NODE_NAME=validate -e CLUSTER_NAME=validate -v "${OUT}:/c:ro" \
    "${OTELCOL_IMAGE}" validate --config="/c/otel-${c}-config.yaml" >/dev/null 2>"${OUT}/err" \
    || { cat "${OUT}/err"; die "the collector rejects the ${c} config"; }
done
ok "the collector accepts the agent and gateway configs"

log "5/7 custom resources vs CRD schemas"
if [[ ! -f "${CACHE_DIR}/crds/.done-v2" ]]; then
  cp charts/log-platform-operators/crds/*.yaml "${CACHE_DIR}/crds/"
  helm template eso charts/log-platform-operators/charts/external-secrets-*.tgz --set installCRDs=true > "${CACHE_DIR}/crds/eso.yaml"
  curl -sSfL -o "${CACHE_DIR}/crds/cilium-cnp.yaml" \
    "https://raw.githubusercontent.com/cilium/cilium/${CILIUM_CRD_VERSION}/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml"
  curl -sSfL -o "${CACHE_DIR}/crds/podmonitor.yaml" \
    "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml"
  touch "${CACHE_DIR}/crds/.done-v2"
fi
[[ -x "${CACHE_DIR}/venv/bin/python" ]] || { python3 -m venv "${CACHE_DIR}/venv" && "${CACHE_DIR}/venv/bin/pip" -q install jsonschema pyyaml; }
helm template log-platform charts/log-platform -n loki --kube-version 1.33.0 "${ENV_VALUES[@]}" \
  -f rendered/values-tenants.yaml --set network.ciliumFqdn.enabled=true > "${OUT}/platform-cilium.yaml"
"${CACHE_DIR}/venv/bin/python" scripts/validate-crs.py --crds "${CACHE_DIR}/crds" \
  --alias monitoring.coreos.com=azmonitoring.coreos.com \
  --manifests "${OUT}/platform-cilium.yaml" "${OUT}/operators.yaml"

log "6/7 alert rules"
docker run --rm -v "${GEN_DIR}/alerts:/r:ro" --entrypoint promtool "${PROMTOOL_IMAGE}" \
  check rules /r/loki-alerts.yaml >/dev/null || die "promtool rejects alerts/loki-alerts.yaml"
ok "alert rules are valid"

log "7/7 terraform"
if command -v terraform >/dev/null; then
  terraform -chdir=infra/terraform init -backend=false -input=false >/dev/null
  terraform -chdir=infra/terraform validate
  terraform -chdir=infra/terraform test >/dev/null || die "terraform test (mocked plan) failed"
  terraform -chdir=infra/terraform fmt -check -recursive >/dev/null || warn "terraform fmt would change files"
else
  warn "terraform not installed: skipped"
fi
ok "All offline checks passed"

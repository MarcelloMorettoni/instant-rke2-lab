#!/usr/bin/env bash
# Offline validation of the charts as they will be installed. No cluster, no Azure.
# Needs helm, python3 and docker; terraform when present.
#
#   scripts/validate.sh [env...]     (default: azure generic)
#
#   1. tenants.yaml valid; rendered/ and generated-images.yaml up to date
#   per environment, as listed in its overlays.txt, plus the variants below:
#   2. both charts render; sign-in providers and guards (environment azure)
#   3. the Loki config the chart produces, and every tenant's limits, load in Loki
#   4. both OTel collector configs the chart produces load in the collector
#   5. every custom resource matches its CRD schema (unknown fields = error)
#   then once:
#   the demo chart (generic/demo): renders, steps/ current, configs and CRs valid
#   6. alert rules pass promtool
#   7. terraform validate + a mocked plan (terraform test)
# Variants: <env>+test-cluster (test overlay added) and <env>+no-kafka.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need helm python3 docker
ENVS=("$@"); [[ ${#ENVS[@]} -gt 0 ]] || ENVS=(azure generic)
cd "${GEN_DIR}"
OUT_ROOT="${CACHE_DIR}/out"; rm -rf "${OUT_ROOT}"; mkdir -p "${OUT_ROOT}" "${CACHE_DIR}/crds"

log "1/7 tenant registry, images"
python3 scripts/render-tenants.py --check
python3 scripts/render-tenants.py >/dev/null
for e in "${ENVS[@]}"; do python3 scripts/render-images.py "${e}" >/dev/null; done
for c in log-platform-operators log-platform; do
  [[ -d "charts/${c}/charts" ]] || helm dependency build "charts/${c}" >/dev/null
done

# CRD schemas (once): ours, ESO's, Strimzi's, Cilium's, the Prometheus Operator's.
if [[ ! -f "${CACHE_DIR}/crds/.done-v4" ]]; then
  rm -rf "${CACHE_DIR}/crds"; mkdir -p "${CACHE_DIR}/crds"
  cp charts/log-platform-operators/crds/*.yaml "${CACHE_DIR}/crds/"
  helm template eso charts/log-platform-operators/charts/external-secrets-*.tgz --set installCRDs=true > "${CACHE_DIR}/crds/eso.yaml"
  tar -xzf charts/log-platform-operators/charts/strimzi-kafka-operator-*.tgz -C "${CACHE_DIR}/crds" --wildcards '*/crds/*'
  curl -sSfL -o "${CACHE_DIR}/crds/cilium-cnp.yaml" \
    "https://raw.githubusercontent.com/cilium/cilium/${CILIUM_CRD_VERSION}/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml"
  for crd in podmonitors prometheusrules; do
    curl -sSfL -o "${CACHE_DIR}/crds/${crd}.yaml" \
      "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_${crd}.yaml"
  done
  mkdir -p "${CACHE_DIR}/crds-examples"
  curl -sSfL -o "${CACHE_DIR}/crds-examples/percona-pg.yaml" \
    "https://raw.githubusercontent.com/percona/percona-postgresql-operator/v${PERCONA_PG_VERSION}/deploy/crd.yaml"
  touch "${CACHE_DIR}/crds/.done-v4"
fi
[[ -x "${CACHE_DIR}/venv/bin/python" ]] || { python3 -m venv "${CACHE_DIR}/venv" && "${CACHE_DIR}/venv/bin/pip" -q install jsonschema pyyaml; }

# check_variant <name> <extra helm args...>: steps 2-5 for one set of values.
check_variant() {
  local name=$1; shift
  local OUT="${OUT_ROOT}/${name}"; mkdir -p "${OUT}"
  log "── ${name}"
  helm template log-platform-operators charts/log-platform-operators -n platform-operators \
    "${ENV_VALUES[@]}" "$@" > "${OUT}/operators.yaml" || die "${name}: the operators chart does not render"
  helm template log-platform charts/log-platform -n loki --kube-version 1.33.0 \
    "${PLATFORM_VALUES[@]}" "$@" > "${OUT}/platform.yaml" || die "${name}: the platform chart does not render"
  ok "2/7 charts render ($(grep -c '^kind:' "${OUT}/platform.yaml") platform objects)"

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
  local f
  for f in "${OUT}"/loki-config*.yaml; do
    docker run --rm -v "${OUT}:/cfg:ro" -e S3_ACCESS_KEY_ID=x -e S3_SECRET_ACCESS_KEY=x "${LOKI_IMAGE}" \
      -config.file="/cfg/$(basename "$f")" -config.expand-env=true -verify-config >/dev/null 2>"${OUT}/err" \
      || { cat "${OUT}/err"; die "${name}: Loki rejects $(basename "$f")"; }
  done
  ok "3/7 Loki accepts the chart's config and every tenant's limits"

  for c in agent gateway; do
    docker run --rm -e MY_POD_IP=127.0.0.1 -e K8S_NODE_NAME=validate -e CLUSTER_NAME=validate -e KAFKA_PASSWORD=validate \
      -v "${OUT}:/c:ro" "${OTELCOL_IMAGE}" validate --config="/c/otel-${c}-config.yaml" >/dev/null 2>"${OUT}/err" \
      || { cat "${OUT}/err"; die "${name}: the collector rejects the ${c} config"; }
  done
  ok "4/7 the collector accepts the agent and gateway configs"

  helm template log-platform charts/log-platform -n loki --kube-version 1.33.0 "${PLATFORM_VALUES[@]}" "$@" \
    --set network.ciliumFqdn.enabled=true > "${OUT}/platform-cilium.yaml"
  "${CACHE_DIR}/venv/bin/python" scripts/validate-crs.py --crds "${CACHE_DIR}/crds" \
    --alias monitoring.coreos.com=azmonitoring.coreos.com \
    --manifests "${OUT}/platform-cilium.yaml" "${OUT}/operators.yaml" > "${OUT}/crs.txt" \
    || { sed 's/^/  /' "${OUT}/crs.txt"; die "${name}: custom resources don't match their CRDs"; }
  ok "5/7 $(tail -1 "${OUT}/crs.txt")"
}


for e in "${ENVS[@]}"; do
  load_env "${e}"
  check_variant "${e}"
  check_variant "${e}+test-cluster" -f environments/overlays/test-cluster.yaml
  check_variant "${e}+no-kafka" -f environments/overlays/no-kafka.yaml
  [[ "${e}" == generic ]] && check_variant "${e}+s3-storage" -f environments/overlays/s3-storage.yaml
  [[ "${e}" == azure ]] || continue
  # Every sign-in provider renders; each missing setting fails with its message.
  for args in "entra" \
              "keycloak --set auth.keycloak.url=https://sso.example --set auth.keycloak.realm=bank" \
              "oidc --set auth.oidc.clientId=g --set auth.oidc.authUrl=https://i/a --set auth.oidc.tokenUrl=https://i/t --set auth.oidc.apiUrl=https://i/u" \
              "disabled"; do
    # shellcheck disable=SC2086
    helm template log-platform charts/log-platform -n loki "${PLATFORM_VALUES[@]}" \
      --set auth.provider=${args} >/dev/null || die "auth.provider ${args%% *} does not render"
  done
  expect_fail() {  # expect_fail "<message part>" <helm args...>
    local msg=$1; shift
    helm template log-platform charts/log-platform -n loki "${PLATFORM_VALUES[@]}" "$@" \
      >/dev/null 2>"${OUT_ROOT}/err" && die "expected a failure ($msg), but it rendered"
    grep -q "$msg" "${OUT_ROOT}/err" || { cat "${OUT_ROOT}/err"; die "wrong failure, expected: $msg"; }
  }
  expect_fail "auth.provider \"ldap\"" --set auth.provider=ldap
  expect_fail "needs auth.keycloak.url" --set auth.provider=keycloak
  expect_fail "needs auth.entra.tenantId" --set auth.provider=entra --set auth.entra.tenantId=
  expect_fail "is not a tenant view" --set auth.provider=disabled --set "auth.mock.users[0].login=zed" --set "auth.mock.users[0].org=nope" --set "auth.mock.users[0].role=Editor"
  expect_fail "kafka.enabled is false but the agents" --set kafka.enabled=false
  expect_fail "kafka.brokers.replicas must be at least 3" --set kafka.brokers.replicas=2
  expect_fail "postgres.provider azure needs keyVault.enabled" --set keyVault.enabled=false --set grafanaAccess.tls.fromKeyVault=false
  expect_fail "keycloak.install: set auth.provider keycloak" --set keycloak.install=true --set keycloak.hostname=sso.example
  ok "sign-in: entra, keycloak, oidc and disabled render; missing settings are refused"
done

log "demo chart (generic/demo): renders, steps/ up to date, Loki + collector configs, CRDs, Python"
DOUT="${OUT_ROOT}/demo"; mkdir -p "${DOUT}"
helm template log-flow-demo demo/chart -n observability > "${DOUT}/demo.yaml" 2>/dev/null || die "the demo chart does not render"
python3 demo/render-steps.py --check >/dev/null || die "generic/demo/steps is out of date: run generic/demo/render-steps.py"
python3 - "${DOUT}" <<'PY'
import sys, yaml, pathlib
out = pathlib.Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all((out / "demo.yaml").read_text()) if d]
cm = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ConfigMap"}
cfg = yaml.safe_load(cm["loki"]["data"]["config.yaml"]); cfg["runtime_config"] = {"file": ""}
(out / "loki.yaml").write_text(yaml.safe_dump(cfg))
(out / "agent.yaml").write_text(cm["otel-agent"]["data"]["relay.yaml"])
(out / "gateway.yaml").write_text(cm["otel-gateway"]["data"]["relay.yaml"])
PY
docker run --rm -v "${DOUT}:/c:ro" "${LOKI_IMAGE}" -config.file=/c/loki.yaml -verify-config >/dev/null 2>"${DOUT}/err" \
  || { cat "${DOUT}/err"; die "Loki rejects the demo's config"; }
for c in agent gateway; do
  docker run --rm -e MY_POD_IP=127.0.0.1 -e K8S_NODE_NAME=validate -e CLUSTER_NAME=demo -v "${DOUT}:/c:ro" \
    "${OTELCOL_IMAGE}" validate --config="/c/${c}.yaml" >/dev/null 2>"${DOUT}/err" \
    || { cat "${DOUT}/err"; die "the collector rejects the demo's ${c} config"; }
done
"${CACHE_DIR}/venv/bin/python" scripts/validate-crs.py --crds "${CACHE_DIR}/crds" --manifests "${DOUT}/demo.yaml" > "${DOUT}/crs.txt" \
  || { cat "${DOUT}/crs.txt"; die "the demo's custom resources don't match their CRDs"; }
for f in demo/chart/files/demonstrator/server.py demo/chart/files/emitter.py demo/render-steps.py; do
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" "${f}" || die "${f}: syntax error"
done
ok "demo: Loki and both collector configs load; $(tail -1 "${DOUT}/crs.txt"); steps/ up to date"

"${CACHE_DIR}/venv/bin/python" scripts/validate-crs.py --crds "${CACHE_DIR}/crds-examples" \
  --manifests examples/ > "${OUT_ROOT}/examples.txt" || { cat "${OUT_ROOT}/examples.txt"; die "examples/ don't match their CRDs"; }
ok "examples: $(tail -1 "${OUT_ROOT}/examples.txt")"

log "6/7 alert rules"
docker run --rm -v "${GEN_DIR}/charts/log-platform/files:/r:ro" --entrypoint promtool "${PROMTOOL_IMAGE}" \
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

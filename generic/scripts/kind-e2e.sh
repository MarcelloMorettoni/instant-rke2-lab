#!/usr/bin/env bash
# In-cluster end-to-end test on a throwaway kind cluster (Docker only).
#
# Proves what pipeline-test.sh can't without Kubernetes: the OTel agent
# identifies an OTLP sender by the pod behind the connection's source IP
# (k8s_attributes, association `from: connection`) and ignores whatever
# namespace or tenant the app claims.
#
#   KIND=/path/to/kind scripts/kind-e2e.sh        # KEEP=1 leaves the cluster running
#
# Deploys the REAL collector chart with log-platform's otelAgent/otelGateway
# values and the rendered configs (rendered/values-tenants.yaml),
# a single-binary Loki with the production limits and otlp_config, and:
#   payments-prod/logger  writes to stdout                         → payments
#   cards/logger          writes to stdout                         → cards
#   cards/liar            OTLP push claiming ns + tenant payments  → cards (not payments)
#   payments-prod/liar    OTLP push claiming ns + tenant cards     → payments (not cards)
# Results are checked inside eval'd assertions, which shellcheck can't follow.
# shellcheck disable=SC2034
set -euo pipefail
source "$(dirname "$0")/lib.sh"
KIND="${KIND:-kind}"
need docker helm kubectl python3 "${KIND}"
CLUSTER="obs-e2e"
CTX="kind-${CLUSTER}"
K() { kubectl --context "${CTX}" "$@"; }
W="$(mktemp -d)"
cleanup() {
  rm -rf "${W}"
  [[ "${KEEP:-0}" == 1 ]] && { warn "KEEP=1: cluster ${CLUSTER} left running"; return; }
  "${KIND}" delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

python3 "${GEN_DIR}/scripts/render-tenants.py" >/dev/null
helm_repos

log "kind cluster ${CLUSTER} (1 control plane + 2 workers)"
cat > "${W}/kind.yaml" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes: [{role: control-plane}, {role: worker}, {role: worker}]
EOF
"${KIND}" get clusters 2>/dev/null | grep -qx "${CLUSTER}" || "${KIND}" create cluster --name "${CLUSTER}" --config "${W}/kind.yaml" --wait 120s
CURL_IMAGE="curlimages/curl:8.16.0"
# The kind nodes pull images themselves (kind load is unreliable with
# multi-arch images in Docker's containerd image store).

log "namespaces, priority classes"
for ns in otel otel-agent loki payments-prod cards; do K create ns "${ns}" --dry-run=client -o yaml | K apply -f - >/dev/null; done
for pc in observability-collector:1000000 observability-critical:900000 observability-high:800000; do
  K create priorityclass "${pc%%:*}" --value="${pc##*:}" --dry-run=client -o yaml | K apply -f - >/dev/null
done

log "Loki (single binary, production limits + otlp_config) as loki-distributor.loki.svc"
python3 - "${GEN_DIR}" "${W}" <<'PY'
import sys, yaml, pathlib
gen, w = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
limits = yaml.safe_load((gen / "charts/log-platform/values.yaml").read_text())["loki"]["loki"]["limits_config"]
overrides = yaml.safe_load((gen / "rendered/values-tenants.yaml").read_text())["loki"]["loki"]["runtimeConfig"]
cfg = {
    "auth_enabled": True,
    "server": {"http_listen_port": 3100, "grpc_listen_port": 9096, "log_level": "warn"},
    "common": {"path_prefix": "/tmp/loki", "replication_factor": 1, "ring": {"kvstore": {"store": "inmemory"}},
               "storage": {"filesystem": {"chunks_directory": "/tmp/loki/chunks", "rules_directory": "/tmp/loki/rules"}}},
    "schema_config": {"configs": [{"from": "2024-01-01", "store": "tsdb", "object_store": "filesystem",
                                    "schema": "v13", "index": {"prefix": "index_", "period": "24h"}}]},
    "limits_config": {**limits, "reject_old_samples": False},
    "runtime_config": {"file": "/etc/loki/runtime.yaml"},
    "analytics": {"reporting_enabled": False},
}
(w / "loki.yaml").write_text(yaml.safe_dump(cfg))
(w / "runtime.yaml").write_text(yaml.safe_dump(overrides))
PY
K -n loki create configmap loki --from-file="${W}/loki.yaml" --from-file="${W}/runtime.yaml" \
  --dry-run=client -o yaml | K apply -f - >/dev/null
K apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: loki, namespace: loki}
spec:
  selector: {matchLabels: {app: loki}}
  template:
    metadata: {labels: {app: loki}}
    spec:
      containers:
        - name: loki
          image: ${LOKI_IMAGE}
          args: [-config.file=/etc/loki/loki.yaml]
          ports: [{containerPort: 3100}]
          readinessProbe: {httpGet: {path: /ready, port: 3100}, periodSeconds: 3}
          volumeMounts: [{name: cfg, mountPath: /etc/loki}, {name: data, mountPath: /tmp/loki}]
      volumes: [{name: cfg, configMap: {name: loki}}, {name: data, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: loki-distributor, namespace: loki}
spec:
  selector: {app: loki}
  ports: [{port: 3100}]
EOF
K -n loki rollout status deploy/loki --timeout=180s >/dev/null

log "OTel gateway + agent: the real chart, log-platform's values, rendered configs (kind overrides only)"
python3 - "${GEN_DIR}" "${W}" <<'PY'
import sys, yaml, pathlib
gen, w = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
chart = yaml.safe_load((gen / "charts/log-platform/values.yaml").read_text())
tenants = yaml.safe_load((gen / "rendered/values-tenants.yaml").read_text())
for key, name in (("otelAgent", "agent"), ("otelGateway", "gateway")):
    v = dict(chart[key]); v.pop("enabled", None); v.pop("namespaceOverride", None)
    v["alternateConfig"] = tenants[key]["alternateConfig"]
    v["global"] = {"clusterName": "kind-e2e"}
    (w / f"{name}-values.yaml").write_text(yaml.safe_dump(v))
PY
cat > "${W}/kind-overrides.yaml" <<EOF
image: {repository: ${OTELCOL_IMAGE%:*}}
nodeSelector: null
tolerations: null
topologySpreadConstraints: null
EOF
cat > "${W}/kind-gateway.yaml" <<'EOF'
replicaCount: 2
resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 1Gi}}
statefulset:
  volumeClaimTemplates:
    - metadata: {name: queue}
      spec: {accessModes: [ReadWriteOnce], storageClassName: standard, resources: {requests: {storage: 1Gi}}}
EOF
helm --kube-context "${CTX}" upgrade --install otel-gateway open-telemetry/opentelemetry-collector \
  --version "${OTEL_CHART_VERSION}" -n otel -f "${W}/gateway-values.yaml" \
  -f "${W}/kind-overrides.yaml" -f "${W}/kind-gateway.yaml" \
  --wait --timeout 5m >/dev/null
helm --kube-context "${CTX}" upgrade --install otel-agent open-telemetry/opentelemetry-collector \
  --version "${OTEL_CHART_VERSION}" -n otel-agent -f "${W}/agent-values.yaml" \
  -f "${W}/kind-overrides.yaml" \
  --set tolerations[0].operator=Exists --wait --timeout 5m >/dev/null

log "tenant workloads"
TS='$(date +%s)000000000'
liar() {  # liar <namespace> <claimed namespace/tenant>
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: liar, namespace: $1, labels: {app.kubernetes.io/name: liar}}
spec:
  restartPolicy: OnFailure
  containers:
    - name: liar
      image: ${CURL_IMAGE}
      command: [sh, -c]
      args:
        - |
          sleep 15
          for i in 1 2 3; do
            curl -sf -X POST -H 'Content-Type: application/json' http://otel-agent.otel-agent.svc:4318/v1/logs -d '{"resourceLogs":[{"resource":{"attributes":[
              {"key":"k8s.namespace.name","value":{"stringValue":"$2"}},{"key":"obs.tenant","value":{"stringValue":"$2"}},
              {"key":"k8s.pod.name","value":{"stringValue":"forged"}},{"key":"service.name","value":{"stringValue":"liar"}}]},
              "scopeLogs":[{"logRecords":[{"timeUnixNano":"'${TS}'","body":{"stringValue":"otlp from $1 claiming $2 card=4111111111111111"}}]}]}]}' && echo sent
            sleep 5
          done
          sleep 3600
EOF
}
logger() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: logger, namespace: $1, labels: {app.kubernetes.io/name: logger}}
spec:
  containers:
    - name: logger
      image: busybox:1.37
      command: [sh, -c, 'while true; do echo "stdout from $1 iban=DE89370400440532013000"; sleep 2; done']
EOF
}
{ logger payments-prod; echo ---; logger cards; echo ---; liar cards payments-prod; echo ---; liar payments-prod cards; } | K apply -f - >/dev/null
K -n cards wait --for=condition=Ready pod/liar pod/logger --timeout=120s >/dev/null
K -n payments-prod wait --for=condition=Ready pod/liar pod/logger --timeout=120s >/dev/null

K -n loki port-forward svc/loki-distributor 13100:3100 >/dev/null 2>&1 &
PF=$!; trap 'kill ${PF} 2>/dev/null || true; cleanup' EXIT
sleep 3
query() {
  curl -sf -G -H "X-Scope-OrgID: $1" -H "X-Loki-Response-Encoding-Flags: categorize-labels" \
    http://127.0.0.1:13100/loki/api/v1/query_range --data-urlencode "query=$2" --data-urlencode 'since=15m' \
    --data-urlencode 'limit=500' | python3 -c '
import json, sys
for s in json.load(sys.stdin)["data"]["result"]:
    for v in s["values"]:
        m = v[2] if len(v) > 2 else {}
        print(json.dumps({"labels": s["stream"], "line": v[1], "meta": m.get("structuredMetadata", {})}))'
}
log "waiting for logs in Loki"
for _ in $(seq 1 60); do
  [[ -n "$(query payments '{service_name="liar"}')" && -n "$(query cards '{service_name="liar"}')" ]] && break; sleep 2
done
PAY="$(query payments '{k8s_cluster_name=~".+"}')"
CARDS="$(query cards '{k8s_cluster_name=~".+"}')"

PASS=0; FAIL=0
t() { if eval "$2"; then ok "PASS  $1"; PASS=$((PASS+1)); else err "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
t "stdout of payments-prod/logger → payments"                    'grep -q "stdout from payments-prod" <<<"${PAY}"'
t "stdout of cards/logger → cards"                               'grep -q "stdout from cards" <<<"${CARDS}"'
t "cards' OTLP push claiming payments-prod → lands in cards"     'grep -q "otlp from cards claiming payments-prod" <<<"${CARDS}"'
t "… and NOT in payments"                                        '! grep -q "otlp from cards" <<<"${PAY}"'
t "payments' OTLP push claiming cards → lands in payments"       'grep -q "otlp from payments-prod claiming cards" <<<"${PAY}"'
t "… and NOT in cards"                                           '! grep -q "otlp from payments-prod" <<<"${CARDS}"'
t "namespace label is the REAL one (cards)"                      'grep "otlp from cards" <<<"${CARDS}" | grep -q "\"k8s_namespace_name\": \"cards\""'
t "forged pod name replaced by the real one (liar)"              'grep "otlp from cards" <<<"${CARDS}" | grep -q "\"k8s_pod_name\": \"liar\""'
t "k8s_attributes added the node name"                           'grep "stdout from cards" <<<"${CARDS}" | grep -q "\"k8s_node_name\": \"obs-e2e-worker"'
t "masking in-cluster (PAN, IBAN)"                               '! grep -qE "4111111111111111|DE89370400440532013000" <<<"${PAY}${CARDS}"'
t "no stream from any other tenant leaks into payments"          '! grep -q "\"k8s_namespace_name\": \"cards\"" <<<"${PAY}"'
echo
if (( FAIL == 0 )); then ok "All ${PASS} in-cluster checks passed"; else
  K -n otel-agent logs ds/otel-agent-agent --tail=30 || true
  die "${FAIL} of $((PASS+FAIL)) in-cluster checks failed"
fi

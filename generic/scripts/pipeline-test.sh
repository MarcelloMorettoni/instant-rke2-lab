#!/usr/bin/env bash
# End-to-end test of the OpenTelemetry pipeline, in Docker, no cluster needed:
#
#   container log files ─┐
#                        ├─► OTel agent ──► Kafka topic otel-logs ──► OTel gateway ──OTLP/HTTP──► Loki
#   an app's OTLP push ──┘   (tenant, mask)                           (route, queue per tenant)
#
#   scripts/pipeline-test.sh              with Kafka (the default pipeline)
#   scripts/pipeline-test.sh --no-kafka   agent ──OTLP/gRPC──► gateway (overlays/no-kafka.yaml)
#
# Uses the RENDERED collector configs and Loki overrides (rendered/values-tenants.yaml)
# and the chart's Loki limits (charts/log-platform/values.yaml). Only differences from
# production: k8s_attributes is removed (no Kubernetes API here), Kafka is one broker
# without TLS/SCRAM (those settings are checked by validate.sh), and endpoints/paths
# point at the test containers.
# That means an OTLP push can't be matched to a pod here, which is exactly
# the "unknown sender" case: it must land in `unassigned`, whatever it claims.
#
# Asserts: tenant routing from the namespace in the file path; no cross-tenant
# reads; PAN/IBAN/bearer masking in bodies AND attributes; only the four
# bounded attributes become stream labels; obs.tenant never reaches Loki; a
# forged namespace/tenant in an OTLP push is ignored.
# Add a sample + an assertion here whenever you add a masking pattern.
# Results are checked inside eval'd assertions, which shellcheck can't follow.
# shellcheck disable=SC2034
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker python3 curl
KAFKA=1; [[ "${1:-}" == "--no-kafka" ]] && KAFKA=0
python3 "${GEN_DIR}/scripts/render-tenants.py" >/dev/null
[[ "$(python3 "${GEN_DIR}/scripts/render-tenants.py" --which payments-prod cards | cut -f2 | tr '\n' ' ')" == "payments cards " ]] \
  || die "the registry no longer maps payments-prod→payments and cards→cards; update this test"

W="$(mktemp -d)"; NET="otel-pipeline-test-$$"
cleanup() {
  docker rm -f "${NET}-loki" "${NET}-gateway" "${NET}-agent" "${NET}-kafka" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${W}"
}
trap cleanup EXIT

# ---- Loki: production limits (per-tenant overrides + otlp_config), local storage
python3 - "${GEN_DIR}" "${W}" "${KAFKA}" <<'PY'
import sys, yaml, pathlib
gen, w = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
kafka = sys.argv[3] == "1"
chart = yaml.safe_load((gen / "charts/log-platform/values.yaml").read_text())
tenants = yaml.safe_load((gen / "rendered/values-tenants.yaml").read_text())
limits = chart["loki"]["loki"]["limits_config"]
overrides = tenants["loki"]["loki"]["runtimeConfig"]
(w / "runtime.yaml").write_text(yaml.safe_dump(overrides))
cfg = {
    "auth_enabled": True,
    "server": {"http_listen_port": 3100, "grpc_listen_port": 9096, "log_level": "warn"},
    "common": {"path_prefix": "/tmp/loki", "replication_factor": 1,
               "ring": {"kvstore": {"store": "inmemory"}},
               "storage": {"filesystem": {"chunks_directory": "/tmp/loki/chunks", "rules_directory": "/tmp/loki/rules"}}},
    "schema_config": {"configs": [{"from": "2024-01-01", "store": "tsdb", "object_store": "filesystem",
                                    "schema": "v13", "index": {"prefix": "index_", "period": "24h"}}]},
    "limits_config": {**limits, "reject_old_samples": False},
    "runtime_config": {"file": "/etc/loki/runtime.yaml"},
    "querier": {"multi_tenant_queries_enabled": True},
    "analytics": {"reporting_enabled": False},
}
(w / "loki.yaml").write_text(yaml.safe_dump(cfg))

# ---- collectors: rendered configs, minus the Kubernetes API, pointed at the test containers
def load(name):
    return tenants[{"agent": "otelAgent", "gateway": "otelGateway"}[name]]["alternateConfig"]

agent = load("agent")
for p in agent["service"]["pipelines"].values():
    p["processors"] = [x for x in p["processors"] if not x.startswith("k8s_attributes")]
for k in [k for k in agent["processors"] if k.startswith("k8s_attributes")]:
    del agent["processors"][k]
agent["extensions"]["file_storage"]["directory"] = "/tmp/otel"
agent["extensions"]["file_storage"]["compaction"]["directory"] = "/tmp/otel"
agent["exporters"]["otlp_grpc/gateway"]["endpoint"] = "dns:///gateway:4317"
if kafka:   # one test broker: plaintext, no SCRAM
    k = agent["exporters"]["kafka"]
    k["brokers"] = ["kafka:9092"]
    k.pop("auth"); k.pop("tls")
else:       # environments/overlays/no-kafka.yaml
    del agent["exporters"]["kafka"]
    for p in agent["service"]["pipelines"].values():
        p["exporters"] = ["otlp_grpc/gateway"]
(w / "agent.yaml").write_text(yaml.safe_dump(agent))

gw = load("gateway")
gw["extensions"]["file_storage"]["directory"] = "/tmp/otel"
gw["extensions"]["file_storage"]["compaction"]["directory"] = "/tmp/otel"
for e in gw["exporters"].values():
    e["endpoint"] = "http://loki:3100/otlp"
    e["sending_queue"]["batch"]["flush_timeout"] = "200ms"
if kafka:
    r = gw["receivers"]["kafka"]
    r["brokers"] = ["kafka:9092"]
    r.pop("auth"); r.pop("tls")
else:
    del gw["receivers"]["kafka"]
    gw["service"]["pipelines"]["logs/in"]["receivers"] = ["otlp"]
(w / "gateway.yaml").write_text(yaml.safe_dump(gw))
PY

# ---- sample container logs, laid out exactly like the kubelet does
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)"
P="${W}/pods/payments-prod_api-7f9c_11111111-2222-3333-4444-555555555555/api"
C="${W}/pods/cards_web-1_66666666-7777-8888-9999-000000000000/web"
X="${W}/pods/random-ns_job-x_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/job"
mkdir -p "$P" "$C" "$X"
printf '%s stdout F payment ok card=4111111111111111 ts=1727530000000 iban=DE89370400440532013000\n' "${NOW}" > "$P/0.log"
printf '%s stdout F Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def\n' "${NOW}" >> "$P/0.log"
printf '%s stderr F cards service started\n' "${NOW}" > "$C/0.log"
printf '%s stdout F stray workload\n' "${NOW}" > "$X/0.log"
chmod -R a+rX "${W}"

docker network create "${NET}" >/dev/null
docker run -d --name "${NET}-loki" --network "${NET}" --network-alias loki -p 127.0.0.1::3100 \
  -v "${W}/loki.yaml:/etc/loki/loki.yaml:ro" -v "${W}/runtime.yaml:/etc/loki/runtime.yaml:ro" \
  "${LOKI_IMAGE}" -config.file=/etc/loki/loki.yaml >/dev/null
LOKI="localhost:$(docker port "${NET}-loki" 3100/tcp | head -1 | cut -d: -f2)"
for _ in $(seq 1 40); do curl -sf "${LOKI}/ready" >/dev/null && break; sleep 1; done
if (( KAFKA )); then
  # One KRaft node, the topic as the chart creates it (fewer partitions).
  docker run -d --name "${NET}-kafka" --network "${NET}" --network-alias kafka \
    -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
    -e KAFKA_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093 -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092 \
    -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka:9093 \
    -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
    -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
    -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=false \
    -e KAFKA_MESSAGE_MAX_BYTES=8388608 -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
    "${KAFKA_IMAGE}" >/dev/null
  KT=(docker exec "${NET}-kafka" /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092)
  for _ in $(seq 1 60); do "${KT[@]}" --list >/dev/null 2>&1 && break; sleep 1; done
  "${KT[@]}" --create --topic otel-logs --partitions 6 --replication-factor 1 \
    --config max.message.bytes=8388608 >/dev/null || die "could not create topic otel-logs"
fi
docker run -d --name "${NET}-gateway" --network "${NET}" --network-alias gateway -e MY_POD_IP=0.0.0.0 \
  --mount type=tmpfs,destination=/tmp/otel,tmpfs-mode=1777 -p 127.0.0.1::8888 \
  -v "${W}/gateway.yaml:/etc/otel/config.yaml:ro" "${OTELCOL_IMAGE}" --config=/etc/otel/config.yaml >/dev/null
docker run -d --name "${NET}-agent" --network "${NET}" -e MY_POD_IP=0.0.0.0 -e K8S_NODE_NAME=test -e CLUSTER_NAME=pipeline-test \
  --mount type=tmpfs,destination=/tmp/otel,tmpfs-mode=1777 \
  -p 127.0.0.1::4318 -p 127.0.0.1::8888 -v "${W}/agent.yaml:/etc/otel/config.yaml:ro" -v "${W}/pods:/var/log/pods:ro" \
  "${OTELCOL_IMAGE}" --config=/etc/otel/config.yaml >/dev/null
AGENT="localhost:$(docker port "${NET}-agent" 4318/tcp | head -1 | cut -d: -f2)"

# The agent tails from the end: append the samples again once it's watching.
sleep 5
for f in "$P/0.log" "$C/0.log" "$X/0.log"; do cp "$f" "$f.tmp"; cat "$f.tmp" >> "$f"; rm "$f.tmp"; done

# An app's OTLP push that lies about who it is.
TS="$(date +%s)000000000"
for _ in $(seq 1 20); do sleep 0.5; curl -sf -X POST -H 'Content-Type: application/json' "http://${AGENT}/v1/logs" -d '{"resourceLogs":[{"resource":{"attributes":[
    {"key":"k8s.namespace.name","value":{"stringValue":"cards"}},
    {"key":"obs.tenant","value":{"stringValue":"cards"}},
    {"key":"service.name","value":{"stringValue":"sdk-app"}}]},
    "scopeLogs":[{"logRecords":[{"timeUnixNano":"'"${TS}"'","body":{"stringValue":"spoof attempt card=5500000000000004"},
    "attributes":[{"key":"iban","value":{"stringValue":"GB82WEST12345698765432"}}]}]}]}]}' >/dev/null && break; done

query() {  # query <tenant> → one JSON object per log line
  curl -sf -G -H "X-Scope-OrgID: $1" -H "X-Loki-Response-Encoding-Flags: categorize-labels" \
    "${LOKI}/loki/api/v1/query_range" --data-urlencode 'query={k8s_cluster_name=~".+"}' \
    --data-urlencode 'since=1h' | python3 -c '
import json, sys
for s in json.load(sys.stdin)["data"]["result"]:
    for v in s["values"]:
        m = v[2] if len(v) > 2 else {}
        print(json.dumps({"labels": s["stream"], "line": v[1], "meta": m.get("structuredMetadata", {})}))'
}
for _ in $(seq 1 90); do
  [[ "$(query payments | wc -l)" -ge 2 && "$(query unassigned | wc -l)" -ge 2 ]] && break; sleep 1
done
sleep 3   # let the gateway commit its last offsets
PAY="$(query payments)"; CARDS="$(query cards)"; UNASSIGNED="$(query unassigned)"; OTHER="$(query lending)"
LABELS="$(curl -sf -H 'X-Scope-OrgID: payments' "${LOKI}/loki/api/v1/labels")"
GW_METRICS="$(curl -sf "localhost:$(docker port "${NET}-gateway" 8888/tcp | head -1 | cut -d: -f2)/metrics")"
AGENT_METRICS="$(curl -sf "localhost:$(docker port "${NET}-agent" 8888/tcp | head -1 | cut -d: -f2)/metrics")"
[[ -n "${SHOW_METRICS:-}" ]] && { grep -E "^otelcol_exporter_(sent|send_failed|queue)" <<<"${GW_METRICS}" >&2; }

PASS=0; FAIL=0
t() { if eval "$2"; then ok "PASS  $1"; PASS=$((PASS+1)); else err "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
t "payments: its 2 file lines, from namespace payments-prod"   '[[ $(grep -c payments-prod <<<"${PAY}") -eq 2 ]]'
t "cards: its 1 line and nothing else"                          '[[ $(wc -l <<<"${CARDS}") -eq 1 ]]'
t "lending: nothing"                                            '[[ -z "${OTHER}" ]]'
t "unmapped namespace → unassigned"                             'grep -q "stray workload" <<<"${UNASSIGNED}"'
t "OTLP push claiming ns/tenant cards → NOT in cards"           '! grep -q "spoof attempt" <<<"${CARDS}"'
t "OTLP push from an unknown sender → unassigned"               'grep -q "spoof attempt" <<<"${UNASSIGNED}"'
t "PAN masked in file logs, last 4 kept"                        'grep -q "card=\*\{12\}1111" <<<"${PAY}"'
t "PAN masked in OTLP body"                                     'grep -q "card=\*\{12\}0004" <<<"${UNASSIGNED}"'
t "full PANs never stored"                                      '! grep -qE "4111111111111111|5500000000000004" <<<"${PAY}${UNASSIGNED}"'
t "epoch-ms timestamp untouched"                                'grep -q "ts=1727530000000" <<<"${PAY}"'
t "IBAN masked in body"                                         'grep -q "iban=DE89\*\*\*\*3000" <<<"${PAY}"'
t "IBAN masked in an OTLP attribute"                            'grep -q "GB82\*\*\*\*5432" <<<"${UNASSIGNED}" && ! grep -q GB82WEST <<<"${UNASSIGNED}"'
t "bearer token redacted"                                       'grep -q "Bearer <redacted>" <<<"${PAY}"'
t "stream labels are exactly the 4 bounded attributes"          'python3 -c "import json,sys; l=set(json.loads(sys.argv[1])[\"data\"]); sys.exit(0 if {\"k8s_cluster_name\",\"k8s_namespace_name\",\"k8s_container_name\",\"service_name\"} <= l and not l & {\"k8s_pod_name\",\"k8s_pod_uid\",\"obs_tenant\",\"log_file_path\"} else 1)" "${LABELS}"'
t "pod name is structured metadata"                             'grep -q "\"k8s_pod_name\": \"api-7f9c\"" <<<"${PAY}"'
t "service.name falls back to the container name"               'grep -q "\"service_name\": \"api\"" <<<"${PAY}"'
t "gateway metrics: records sent to Loki per tenant"           'grep -qE "^otelcol_exporter_sent_log_records\{.*exporter=\"otlp_http/payments\".* [1-9]" <<<"${GW_METRICS}"'
t "agent metrics: nothing failed to send"                       '! grep -qE "^otelcol_exporter_send_failed_log_records\{.* [1-9]" <<<"${AGENT_METRICS}"'
t "obs.tenant never reaches Loki"                               '! grep -q obs_tenant <<<"${PAY}${CARDS}${UNASSIGNED}"'
if (( KAFKA )); then
  GROUP="$(docker exec "${NET}-kafka" /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
    --describe --group otel-gateway 2>/dev/null || true)"
  t "agent wrote to Kafka (kafka exporter)"                     'grep -qE "^otelcol_exporter_sent_log_records\{.*exporter=\"kafka\".* [1-9]" <<<"${AGENT_METRICS}"'
  t "gateway read from Kafka (kafka receiver)"                  'grep -qE "^otelcol_receiver_accepted_log_records\{.*receiver=\"kafka\".* [1-9]" <<<"${GW_METRICS}"'
  t "consumer group otel-gateway has no lag"                    'awk "\$1==\"otel-gateway\" && \$6 ~ /^[0-9]+$/ {n++; if (\$6 != 0) bad=1} END {exit (n>0 && !bad) ? 0 : 1}" <<<"${GROUP}"'

  # The point of Kafka: while the gateways are down, logs wait in Kafka, not on the node.
  docker stop -t 30 "${NET}-gateway" >/dev/null
  printf '%s stdout F written while the gateway was down\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)" >> "$P/0.log"
  lag() {
    docker exec "${NET}-kafka" /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
      --describe --group otel-gateway 2>/dev/null | awk '$1=="otel-gateway" && $6 ~ /^[0-9]+$/ {s+=$6} END {print s+0}'
  }
  for _ in $(seq 1 30); do [[ "$(lag)" -gt 0 ]] && break; sleep 1; done
  BACKLOG="$(lag)"
  t "gateway down: the new logs wait in Kafka (lag ${BACKLOG})"  '[[ "${BACKLOG}" -gt 0 ]]'
  docker start "${NET}-gateway" >/dev/null
  for _ in $(seq 1 90); do query payments | grep -q "while the gateway was down" && break; sleep 1; done
  t "gateway back: the backlog reaches Loki, in the right tenant" 'query payments | grep -q "while the gateway was down"'
fi
echo
if (( FAIL == 0 )); then ok "All ${PASS} pipeline checks passed ($( (( KAFKA )) && echo "agent → Kafka → gateway" || echo "agent → gateway, no Kafka"))"; else
  docker logs "${NET}-agent" 2>&1 | tail -20; docker logs "${NET}-gateway" 2>&1 | tail -20
  (( KAFKA )) && { echo "${GROUP:-}"; docker logs "${NET}-kafka" 2>&1 | tail -10; }
  die "${FAIL} of $((PASS+FAIL)) pipeline checks failed"
fi

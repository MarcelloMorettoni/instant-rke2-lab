#!/usr/bin/env bash
# The demonstrator, end to end, in Docker (no cluster): one traced line from the
# tenant app through the REAL components, followed by the demonstrator's code.
#
#   generic/demo/test-demonstrator.sh
#
# Real: Kafka 4.3.1 + Strimzi's HTTP bridge + kafka_exporter, the OTel agent and
# gateway with the chart's RENDERED configs, Loki 3.6.11 with the chart's
# recording rules, SeaweedFS (S3), Prometheus + prom-label-proxy, the tenant
# app (emitter.py) and the demonstrator (server.py).
# Stand-ins: a static pod list instead of the Kubernetes API (STATIC_DISCOVERY);
# one Loki process plays every Loki component; a small script plays the
# read gateway (views, keys, X-Scope-OrgID / X-Obs-Tenant); the agent is told
# the namespace instead of asking Kubernetes (no k8s_attributes here); rules run
# every 10 s and chunks flush after 20 s idle, so the test takes ~2 minutes.
# Results are checked inside eval'd assertions, which shellcheck can't follow.
# shellcheck disable=SC2034
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need docker python3 curl helm
DEMO="${GEN_DIR}/demo"
BRIDGE_IMAGE="quay.io/strimzi/kafka-bridge:1.1.0"
KEXP_IMAGE="danielqsj/kafka-exporter:v1.9.0"
SEAWEED_IMAGE="chrislusf/seaweedfs:4.48"
PY_IMAGE="python:3.13-alpine"
W="$(mktemp -d)"; NET="demo-test-$$"
NAMES=(kafka bridge kexp s3 metrics guard loki gw agent emitter fakegw demo)
cleanup() {
  for n in "${NAMES[@]}"; do docker rm -f "${NET}-${n}" >/dev/null 2>&1 || true; done
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${W}"
}
[[ -n "${DEMO_TEST_KEEP:-}" ]] || trap cleanup EXIT

# ---- the chart's rendered configs, adapted to the test containers
helm template log-flow-demo "${DEMO}/chart" -n observability > "${W}/chart.yaml" 2>/dev/null
mkdir -p "${W}/keys" "${W}/rules" "${W}/code" "${W}/bridge"
python3 - "${W}" <<'PY'
import sys, yaml, pathlib, hashlib
w = pathlib.Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all((w / "chart.yaml").read_text()) if d]
cm = {d["metadata"]["name"]: d for d in docs if d["kind"] == "ConfigMap"}
loki = yaml.safe_load(cm["loki"]["data"]["config.yaml"])
values_rules = {d["metadata"]["name"]: d["data"] for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"].startswith("loki-ruler-rules-")}

# Loki: the chart's limits, OTLP labels and ruler settings; one process; fast flush.
cfg = {
    "auth_enabled": True,
    "server": {"http_listen_port": 3100, "grpc_listen_port": 9096, "log_level": "warn"},
    "common": {"path_prefix": "/tmp/loki", "replication_factor": 1, "ring": {"kvstore": {"store": "inmemory"}},
               "storage": {"s3": {"endpoint": "seaweedfs:8333", "bucketnames": "loki-chunks", "region": "us-east-1",
                                  "access_key_id": "demo", "secret_access_key": "demo",
                                  "s3forcepathstyle": True, "insecure": True}}},
    "schema_config": loki["schema_config"],
    "limits_config": {**loki["limits_config"], "reject_old_samples": False},
    "ingester": {"chunk_idle_period": "20s", "max_chunk_age": "1m", "flush_check_period": "5s"},
    "querier": {"multi_tenant_queries_enabled": True},
    "ruler": {**{k: v for k, v in loki["ruler"].items() if k not in ("remote_write", "wal", "rule_path")},
              "wal": {"dir": "/tmp/loki/ruler-wal"}, "rule_path": "/tmp/loki/rules-tmp",
              "remote_write": {"enabled": True, "add_org_id_header": False,
                               "clients": {"metrics-store-0": {"url": "http://metrics:9090/api/v1/write"}}}},
    "analytics": {"reporting_enabled": False},
}
(w / "loki.yaml").write_text(yaml.safe_dump(cfg))
for name, files in values_rules.items():
    tenant = name.replace("loki-ruler-rules-", "")
    d = w / "rules" / tenant
    d.mkdir(parents=True)
    rules = yaml.safe_load(files["rules.yaml"])
    for g in rules["groups"]:
        g["interval"] = "10s"
        for r in g["rules"]:
            r["expr"] = r["expr"].replace("offset 30s", "offset 5s")
    (d / "rules.yaml").write_text(yaml.safe_dump(rules, sort_keys=False))

# Agent: the chart's config, minus what needs a node (files) or the Kubernetes API.
agent = yaml.safe_load(cm["otel-agent"]["data"]["relay.yaml"])
del agent["receivers"]["file_log"]
del agent["service"]["pipelines"]["logs/files"]
for k in [k for k in agent["processors"] if k.startswith("k8s_attributes")]:
    del agent["processors"][k]
agent["processors"]["resource/what-kubernetes-would-say"] = {"attributes": [
    {"key": "k8s.namespace.name", "value": "tenant-a", "action": "upsert"},
    {"key": "k8s.pod.name", "value": "payments-test", "action": "upsert"},
    {"key": "k8s.container.name", "value": "payments", "action": "upsert"}]}
p = agent["service"]["pipelines"]["logs/otlp"]
p["processors"] = [x if not x.startswith("k8s_attributes") else "resource/what-kubernetes-would-say" for x in p["processors"]]
agent["extensions"]["file_storage"]["directory"] = agent["extensions"]["file_storage"]["compaction"]["directory"] = "/tmp/otel"
agent["exporters"]["kafka"]["brokers"] = ["kafka:9092"]
(w / "agent.yaml").write_text(yaml.safe_dump(agent))

gw = yaml.safe_load(cm["otel-gateway"]["data"]["relay.yaml"])
gw["receivers"]["kafka"]["brokers"] = ["kafka:9092"]
gw["extensions"]["file_storage"]["directory"] = gw["extensions"]["file_storage"]["compaction"]["directory"] = "/tmp/otel"
for e in gw["exporters"].values():
    e["endpoint"] = "http://loki:3100/otlp"
    e["sending_queue"]["batch"]["flush_timeout"] = "200ms"
(w / "gateway.yaml").write_text(yaml.safe_dump(gw))

# The views' keys, as the chart derives them.
secret = next(d for d in docs if d["kind"] == "Secret" and d["metadata"]["name"] == "obs-gateway-keys")
for k, v in secret["stringData"].items():
    (w / "keys" / k).write_text(v)
PY
cp "${DEMO}/chart/files/demonstrator/server.py" "${DEMO}/chart/files/demonstrator/index.html" "${W}/code/"
cp "${DEMO}/chart/files/emitter.py" "${W}/code/"
printf 'bridge.id=demo\nkafka.bootstrap.servers=kafka:9092\nhttp.host=0.0.0.0\nhttp.port=8080\n' > "${W}/bridge/application.properties"
printf 'global: {}\n' > "${W}/prometheus.yml"
cat > "${W}/code/fakegw.py" <<'PY'
"""Plays the read gateway: /<view>/loki/api/v1/... and /<view>/prometheus/api/v1/... with the view's key."""
import os, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
VIEWS = {"tenant-a": "tenant-a", "tenant-b": "tenant-b", "tenant-c": "tenant-c",
         "platform": "platform|unassigned|tenant-a|tenant-b|tenant-c"}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.split("/", 2)
        view, rest = (parts[1], "/" + parts[2]) if len(parts) == 3 else ("", "")
        if view not in VIEWS:
            return self.reply(404, b"no route")
        if self.headers.get("X-Api-Key") != open(f"/keys/obs-key-{view}").read().strip():
            return self.reply(401, b"bad key")
        if rest.startswith("/loki/api/v1"):
            url, hdr = "http://loki:3100" + rest, {"X-Scope-OrgID": VIEWS[view]}
        elif rest.startswith("/prometheus/api/v1"):
            url, hdr = "http://guard:8080" + rest[len("/prometheus"):], {"X-Obs-Tenant": VIEWS[view]}
        else:
            return self.reply(404, b"no route")
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=60) as r:
                self.reply(r.status, r.read())
        except urllib.error.HTTPError as e:
            self.reply(e.code, e.read())
    def reply(self, code, body):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
PY
chmod -R a+rX "${W}"

# ---- the containers
docker network create "${NET}" >/dev/null
run() { local n=$1; shift; docker run -d --name "${NET}-${n}" --network "${NET}" --network-alias "${n}" "$@" >/dev/null; }
run kafka -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093 -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka:9093 \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=false -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
  "${KAFKA_IMAGE}"
run s3 --network-alias seaweedfs "${SEAWEED_IMAGE}" server -s3 -dir=/data -volume.max=10 -master.volumeSizeLimitMB=64
run metrics -v "${W}/prometheus.yml:/etc/prometheus/prometheus.yml:ro" "${PROMTOOL_IMAGE}" \
  --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --web.enable-remote-write-receiver
run guard "${PROM_LABEL_PROXY_IMAGE}" -insecure-listen-address=0.0.0.0:8080 -upstream=http://metrics:9090 \
  -label=tenant -header-name=X-Obs-Tenant -regex-match -enable-label-apis
KT=(docker exec "${NET}-kafka" /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092)
for _ in $(seq 1 60); do "${KT[@]}" --list >/dev/null 2>&1 && break; sleep 1; done
"${KT[@]}" --create --topic otel-logs --partitions 6 --replication-factor 1 >/dev/null
for _ in $(seq 1 30); do
  docker run --rm --network "${NET}" "${PY_IMAGE}" python3 -c "
import urllib.request
for b in ('loki-chunks', 'loki-ruler'):
    urllib.request.urlopen(urllib.request.Request(f'http://seaweedfs:8333/{b}', method='PUT'), timeout=5)" >/dev/null 2>&1 && break
  sleep 2
done
run bridge -v "${W}/bridge:/config:ro" "${BRIDGE_IMAGE}" /opt/strimzi/bin/kafka_bridge_run.sh --config-file=/config/application.properties
run kexp "${KEXP_IMAGE}" --kafka.server=kafka:9092 --web.listen-address=:9404
run loki -v "${W}/loki.yaml:/etc/loki/loki.yaml:ro" -v "${W}/rules:/etc/loki/rules:ro" "${LOKI_IMAGE}" -config.file=/etc/loki/loki.yaml
run gw -e MY_POD_IP=0.0.0.0 --mount type=tmpfs,destination=/tmp/otel,tmpfs-mode=1777 \
  -v "${W}/gateway.yaml:/c.yaml:ro" "${OTELCOL_IMAGE}" --config=/c.yaml
run agent -e MY_POD_IP=0.0.0.0 -e K8S_NODE_NAME=node-1 -e CLUSTER_NAME=demo --mount type=tmpfs,destination=/tmp/otel,tmpfs-mode=1777 \
  -v "${W}/agent.yaml:/c.yaml:ro" "${OTELCOL_IMAGE}" --config=/c.yaml
run emitter -e APP=payments -e POD_NAME=payments-test -e NODE_NAME=node-1 -e POD_NAMESPACE=tenant-a \
  -e OTEL_AGENT_URL=http://agent:4318/v1/logs -v "${W}/code:/app:ro" "${PY_IMAGE}" python3 -u /app/emitter.py 8080
run fakegw -v "${W}/code:/app:ro" -v "${W}/keys:/keys:ro" "${PY_IMAGE}" python3 -u /app/fakegw.py

# ---- the static "Kubernetes": which pod is which container
ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${NET}-$1"; }
python3 - "${W}/pods.json" "$(ip agent)" "$(ip kafka)" "$(ip kexp)" "$(ip gw)" "$(ip loki)" "$(ip s3)" "$(ip metrics)" "$(ip guard)" "$(ip fakegw)" "$(ip emitter)" <<'PY'
import json, sys
out, agent, kafka, kexp, gw, loki, s3, metrics, guard, fakegw, emitter = sys.argv[1:]
ns = "observability"
def pod(name, ip, node): return {"name": name, "ip": ip, "node": node, "ready": True}
loki_sel = "app.kubernetes.io/name=loki,app.kubernetes.io/component="
pods = {
    f"{ns}|app.kubernetes.io/name=otel-agent": [pod("otel-agent-x7k2p", agent, "node-1")],
    f"{ns}|strimzi.io/cluster=logs,strimzi.io/broker-role=true": [pod("logs-dual-1", kafka, "node-1")],
    f"{ns}|strimzi.io/name=logs-kafka-exporter": [pod("logs-kafka-exporter-5c9", kexp, "node-2")],
    f"{ns}|app.kubernetes.io/name=otel-gateway": [pod("otel-gateway-0", gw, "node-2")],
    f"{ns}|app.kubernetes.io/name=seaweedfs": [pod("seaweedfs-0", s3, "node-2")],
    f"{ns}|gateway.networking.k8s.io/gateway-name=obs-gateway": [pod("obs-gateway-6d8", fakegw, "node-1")],
    f"{ns}|app.kubernetes.io/name=obs-metrics": [pod("obs-metrics-0", metrics, "node-2")],
    f"{ns}|app.kubernetes.io/name=obs-metrics-proxy": [pod("obs-metrics-proxy-7f", guard, "node-1")],
    "tenant-a|app.kubernetes.io/component=emitter": [pod("payments-test", emitter, "node-1")],
}
for comp in ("distributor", "query-frontend", "query-scheduler", "querier", "index-gateway", "compactor", "ruler"):
    pods[f"{ns}|{loki_sel}{comp}"] = [pod(f"loki-{comp}-0", loki, "node-2")]
pods[f"{ns}|{loki_sel}ingester"] = [pod("loki-ingester-zone-a-0", loki, "node-2")]
json.dump({"pods": pods, "nodes": {"node-1": "zone-1", "node-2": "zone-2"}}, open(out, "w"), indent=1)
PY
chmod a+r "${W}/pods.json"
run demo -p 127.0.0.1::8080 -v "${W}/code:/app:ro" -v "${W}/keys:/keys:ro" -v "${W}/pods.json:/static/pods.json:ro" \
  -e STATIC_DISCOVERY=/static/pods.json -e READ_GATEWAY=http://fakegw:8080 -e KAFKA_BRIDGE=http://bridge:8080 \
  -e S3_URL=http://seaweedfs:8333 -e EMITTER_URL=http://emitter:8080 -e TENANTS=tenant-a,tenant-b,tenant-c \
  -e 'TENANT_APPS={"tenant-a":"payments","tenant-b":"orders","tenant-c":"inventory"}' "${PY_IMAGE}" python3 -u /app/server.py
D="localhost:$(docker port "${NET}-demo" 8080/tcp | head -1 | cut -d: -f2)"
for _ in $(seq 1 60); do
  curl -sf "http://${D}/healthz" >/dev/null && docker exec "${NET}-loki" wget -qO- localhost:3100/ready 2>/dev/null | grep -q ready && break
  sleep 2
done
sleep 10    # bridge, gateway consumer group, agent: settle

PASS=0; FAIL=0
t() { if eval "$2"; then ok "PASS  $1"; PASS=$((PASS+1)); else err "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
TOPO="$(curl -sf "http://${D}/api/topology")"
t "topology: lists the components and their pods" 'python3 -c "import json,sys; t=json.loads(sys.argv[1]); c={x[\"key\"]:x[\"total\"] for x in t[\"components\"]}; sys.exit(0 if c[\"agent\"]==1 and c[\"ingester\"]==1 and c[\"kafka\"]==1 else 1)" "${TOPO}"'
t "topology: Kafka partitions from the exporter" 'python3 -c "import json,sys; sys.exit(0 if len(json.loads(sys.argv[1])[\"partitions\"])==6 else 1)" "${TOPO}"'
t "the web page is served" 'curl -sf "http://${D}/" | grep -q "Log flow demonstrator"'
ID="$(curl -sf -X POST -H 'Content-Type: application/json' "http://${D}/api/trace" -d '{"tenant":"tenant-a","message":"hello from the test"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
t "a second trace while one runs is refused (409)" '[[ "$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" "http://${D}/api/trace" -d "{\"tenant\":\"tenant-b\"}")" == 409 ]]'
log "trace ${ID}: following (up to 6 min)"
for _ in $(seq 1 180); do
  TR="$(curl -sf "http://${D}/api/trace/${ID}")"
  python3 -c "import json,sys; sys.exit(0 if json.loads(sys.argv[1])['finished'] else 1)" "${TR}" && break
  sleep 2
done
python3 -c "
import json, sys
tr = json.loads(sys.argv[1])
for s in tr['stages']:
    print(f\"  {s['status']:8} {s['title']:18} {(s.get('ms') or 0)/1000:6.1f}s  {s['summary'][:110]}\")" "${TR}"
st() { python3 -c "import json,sys; print({s['key']: s['status'] for s in json.loads(sys.argv[1])['stages']}['$1'])" "${TR}"; }
for stage in app agent kafka gateway distributor ingesters query isolation storage ruler; do
  t "stage ${stage} confirmed" '[[ "$(st '"${stage}"')" == done ]]'
done
t "kafka: found the record at a partition and offset" 'python3 -c "import json,sys; d=[s for s in json.loads(sys.argv[1])[\"stages\"] if s[\"key\"]==\"kafka\"][0][\"data\"]; sys.exit(0 if \"hit\" in d and \"offset\" in d else 1)" "${TR}"'
t "query: the line came back with its namespace label" 'python3 -c "import json,sys; d=[s for s in json.loads(sys.argv[1])[\"stages\"] if s[\"key\"]==\"query\"][0]; sys.exit(0 if \"k8s_namespace_name=tenant-a\" in json.dumps(d) else 1)" "${TR}"'
t "ruler: recorded series stamped tenant=tenant-a" 'python3 -c "import json,sys; d=[s for s in json.loads(sys.argv[1])[\"stages\"] if s[\"key\"]==\"ruler\"][0][\"data\"]; sys.exit(0 if d.get(\"labels\",{}).get(\"tenant\")==\"tenant-a\" else 1)" "${TR}"'
# ---- "Generate workload": a burst from tenant-a's app, seen at every hop
LOAD="$(curl -sf -X POST -H 'Content-Type: application/json' "http://${D}/api/load" \
  -d '{"tenant":"tenant-a","lines_per_second":40,"seconds":20,"via":"otlp"}')"
t "workload: the tenant app accepted the burst" 'grep -q "\"burst\"" <<<"${LOAD}"'
flow_ok() {
  curl -sf "http://${D}/api/flow" | python3 -c '
import json, sys
f = json.load(sys.stdin)
ok = (f.get("ready") and f["per_tenant"].get("tenant-a", 0) > 5
      and sum(a["lines_in"] for a in f["agents"]) > 5
      and sum(k["messages"] for k in f["kafka"]) > 0
      and sum(g["by_tenant"].get("tenant-a", 0) for g in f["gateways"]) > 5
      and sum(d["by_tenant"].get("tenant-a", 0) for d in f["distributors"]) > 5
      and sum(i["pushes"] for i in f["ingesters"]) > 0)
print(json.dumps({k: f.get(k) for k in ("per_tenant",)}))
sys.exit(0 if ok else 1)'
}
for _ in $(seq 1 15); do flow_ok >/dev/null && break; sleep 2; done
t "workload: tenant-a's burst is visible at the agent, Kafka, gateway, distributor and ingester" 'flow_ok >/dev/null'
t "workload: the ruler sees tenant-a too" 'curl -sf "http://${D}/api/flow" | python3 -c "import json,sys; sys.exit(0 if \"tenant-a\" in json.load(sys.stdin).get(\"ruler\", {}) else 1)"'

echo
if (( FAIL == 0 )); then ok "All ${PASS} demonstrator checks passed"; else
  for n in demo agent gw loki; do echo "--- ${n}"; docker logs "${NET}-${n}" 2>&1 | tail -8; done
  die "${FAIL} of $((PASS+FAIL)) demonstrator checks failed"
fi

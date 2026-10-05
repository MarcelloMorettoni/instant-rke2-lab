"""Log flow demonstrator: follow ONE log line through the platform.

Python standard library only (runs on python:3.13-alpine, code from a
ConfigMap). Every fact it shows comes from the real components:
  - Kubernetes API         which pods run where (nodes, zones)
  - each pod's /metrics    which agent, gateway, distributor, ingesters,
                           frontend, scheduler and queriers handled the line
  - Kafka (HTTP bridge)    the record itself: partition, offset, key
  - Loki (read gateway)    the query result and its stats
  - object storage (S3)    the flushed chunk
  - metrics store (guard)  the ruler's recorded series

  GET  /                 the web page (index.html)
  GET  /api/topology     components, pods, Kafka partitions, live rates
  POST /api/load         {"tenant", "lines_per_second", "seconds", "via"}: extra workload from the tenant's app
  GET  /api/flow         live throughput at every hop, per pod (sampled every 3 s while someone watches)
  POST /api/trace        {"tenant", "message"} → {"id"}
  GET  /api/trace/<id>   the trace's stages so far
"""
import base64
import json
import os
import re
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = os.environ.get("NAMESPACE", "observability")
TENANTS = [t for t in os.environ.get("TENANTS", "tenant-a,tenant-b,tenant-c").split(",") if t]
APPS = json.loads(os.environ.get("TENANT_APPS", "{}"))
GATEWAY = os.environ.get("READ_GATEWAY", f"http://obs-gateway.{NS}.svc.cluster.local:8080")
BRIDGE = os.environ.get("KAFKA_BRIDGE", f"http://logs-bridge-service.{NS}.svc.cluster.local:8080")
S3 = os.environ.get("S3_URL", f"http://seaweedfs.{NS}.svc.cluster.local:8333")
EMITTER = os.environ.get("EMITTER_URL", "http://emitter.{tenant}.svc.cluster.local:8080")
TOPIC = os.environ.get("TOPIC", "otel-logs")
PARTITIONS = int(os.environ.get("PARTITIONS", "6"))
KEYS_DIR = os.environ.get("KEYS_DIR", "/keys")
K8S = os.environ.get("K8S_API", "https://kubernetes.default.svc")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
STATIC = os.environ.get("STATIC_DISCOVERY", "")      # tests: a JSON file instead of the Kubernetes API
HERE = os.path.dirname(os.path.abspath(__file__))

# component key, title, label selector, metrics port
COMPONENTS = [
    ("agent", "OTel agents", "app.kubernetes.io/name=otel-agent", 8888),
    ("kafka", "Kafka brokers", "strimzi.io/cluster=logs,strimzi.io/broker-role=true", None),
    ("kafka-exporter", "Kafka exporter", "strimzi.io/name=logs-kafka-exporter", 9404),
    ("gateway", "OTel gateways", "app.kubernetes.io/name=otel-gateway", 8888),
    ("distributor", "Distributors", "app.kubernetes.io/name=loki,app.kubernetes.io/component=distributor", 3100),
    ("ingester", "Ingesters", "app.kubernetes.io/name=loki,app.kubernetes.io/component=ingester", 3100),
    ("object-storage", "Object storage", "app.kubernetes.io/name=seaweedfs", None),
    ("grafana", "Grafana", "app.kubernetes.io/name=grafana", None),
    ("read-gateway", "Read gateway", "gateway.networking.k8s.io/gateway-name=obs-gateway", None),
    ("query-frontend", "Query frontends", "app.kubernetes.io/name=loki,app.kubernetes.io/component=query-frontend", 3100),
    ("query-scheduler", "Query schedulers", "app.kubernetes.io/name=loki,app.kubernetes.io/component=query-scheduler", 3100),
    ("querier", "Queriers", "app.kubernetes.io/name=loki,app.kubernetes.io/component=querier", 3100),
    ("index-gateway", "Index gateways", "app.kubernetes.io/name=loki,app.kubernetes.io/component=index-gateway", 3100),
    ("compactor", "Compactor", "app.kubernetes.io/name=loki,app.kubernetes.io/component=compactor", 3100),
    ("ruler", "Ruler", "app.kubernetes.io/name=loki,app.kubernetes.io/component=ruler", 3100),
    ("metrics-store", "Metrics store", "app.kubernetes.io/name=obs-metrics", 9090),
    ("guard", "Tenant guard", "app.kubernetes.io/name=obs-metrics-proxy", None),
]
PORTS = {c[0]: c[3] for c in COMPONENTS}


# --------------------------------------------------------------------------- HTTP
def http(method, url, body=None, headers=None, timeout=10, ctx=None):
    """(status, body): JSON decoded when possible, else bytes. Never raises for HTTP errors."""
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    except (urllib.error.URLError, OSError) as e:
        return 0, str(e)
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, raw


# --------------------------------------------------------------------------- Kubernetes
_K8S_CTX = None


def k8s(path):
    global _K8S_CTX
    if _K8S_CTX is None and os.path.exists(f"{SA_DIR}/ca.crt"):
        _K8S_CTX = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    headers = {}
    if os.path.exists(f"{SA_DIR}/token"):
        headers["Authorization"] = "Bearer " + open(f"{SA_DIR}/token").read().strip()
    status, body = http("GET", K8S + path, headers=headers, ctx=_K8S_CTX)
    return body if status == 200 and isinstance(body, dict) else {}


def pods(selector, namespace=NS):
    if STATIC:
        items = json.load(open(STATIC)).get("pods", {}).get(f"{namespace}|{selector}", [])
        return [dict(p, ready=p.get("ready", True)) for p in items]
    q = urllib.parse.urlencode({"labelSelector": selector})
    out = []
    for p in k8s(f"/api/v1/namespaces/{namespace}/pods?{q}").get("items", []):
        conds = {c["type"]: c["status"] for c in p.get("status", {}).get("conditions", [])}
        out.append({"name": p["metadata"]["name"], "ip": p.get("status", {}).get("podIP"),
                    "node": p.get("spec", {}).get("nodeName"), "ready": conds.get("Ready") == "True",
                    "labels": p["metadata"].get("labels", {})})
    return sorted(out, key=lambda p: p["name"])


_NODES = {"t": 0, "zones": {}}


def node_zones():
    if STATIC:
        return json.load(open(STATIC)).get("nodes", {})
    if time.time() - _NODES["t"] > 60:
        zones = {}
        for n in k8s("/api/v1/nodes").get("items", []):
            labels = n["metadata"].get("labels", {})
            zones[n["metadata"]["name"]] = labels.get("topology.kubernetes.io/zone", "")
        _NODES.update(t=time.time(), zones=zones)
    return _NODES["zones"]


def ingester_zone(name):
    m = re.search(r"zone-([a-z])", name)
    return f"zone-{m.group(1)}" if m else "?"


# --------------------------------------------------------------------------- metrics
_SAMPLE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)')
_LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')


def scrape(pod, port):
    """[(name, labels, value)] from http://<pod ip>:<port>/metrics."""
    if not pod.get("ip") or not port:
        return []
    status, body = http("GET", f"http://{pod['ip']}:{port}/metrics", timeout=4)
    if status != 200:
        return []
    text = body.decode() if isinstance(body, bytes) else str(body)
    out = []
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        m = _SAMPLE.match(line)
        if m:
            try:
                out.append((m.group(1), dict(_LABEL.findall(m.group(2) or "")), float(m.group(3))))
            except ValueError:
                pass
    return out


def total(samples, name, **match):
    return sum(v for n, labels, v in samples
               if n == name and all(labels.get(k) == str(val) for k, val in match.items()))


def per_pod(component, name, **match):
    """{pod name: summed value} for one metric across a component's pods."""
    port = PORTS[component]
    selector = next(c[2] for c in COMPONENTS if c[0] == component)
    return {p["name"]: total(scrape(p, port), name, **match) for p in pods(selector)}


def deltas(before, after):
    return {k: after.get(k, 0) - before.get(k, 0) for k in after if after.get(k, 0) - before.get(k, 0) > 0}


def kafka_partitions():
    """{partition: {end_offset, leader, replicas, isr}} from the Kafka exporter."""
    exp = pods("strimzi.io/name=logs-kafka-exporter")
    samples = scrape(exp[0], 9404) if exp else []
    parts = {}
    for n, labels, v in samples:
        if labels.get("topic") != TOPIC or "partition" not in labels:
            continue
        p = parts.setdefault(int(labels["partition"]), {})
        key = {"kafka_topic_partition_current_offset": "end_offset", "kafka_topic_partition_leader": "leader",
               "kafka_topic_partition_replicas": "replicas", "kafka_topic_partition_in_sync_replica": "isr"}.get(n)
        if key:
            p[key] = int(v)
    return parts


def broker_pod(broker_id):
    for p in pods("strimzi.io/cluster=logs,strimzi.io/broker-role=true"):
        if p["name"].rsplit("-", 1)[-1] == str(broker_id):
            return p
    return None


# --------------------------------------------------------------------------- Loki / gateway
def key(view):
    try:
        return open(f"{KEYS_DIR}/obs-key-{view}").read().strip()
    except OSError:
        return ""


def loki_query(view, logql, start_ns, end_ns, api_key=None):
    q = urllib.parse.urlencode({"query": logql, "start": str(start_ns), "end": str(end_ns), "limit": "20"})
    return http("GET", f"{GATEWAY}/{view}/loki/api/v1/query_range?{q}",
                headers={"X-Api-Key": api_key if api_key is not None else key(view)}, timeout=60)


def prom_query(view, promql):
    q = urllib.parse.urlencode({"query": promql})
    return http("GET", f"{GATEWAY}/{view}/prometheus/api/v1/query?{q}", headers={"X-Api-Key": key(view)}, timeout=30)


def s3_keys(prefix):
    """{key: (size, last_modified)} under prefix in loki-chunks (anonymous listing: demo storage)."""
    out, token = {}, None
    for _ in range(20):
        params = {"list-type": "2", "prefix": prefix, "max-keys": "1000"}
        if token:
            params["continuation-token"] = token
        status, body = http("GET", f"{S3}/loki-chunks?{urllib.parse.urlencode(params)}", timeout=10)
        if status != 200:
            raise RuntimeError(f"object storage listing failed (HTTP {status})")
        xml = body.decode() if isinstance(body, bytes) else str(body)
        for c in re.findall(r"<Contents>(.*?)</Contents>", xml, re.S):
            k = re.search(r"<Key>([^<]+)</Key>", c)
            s = re.search(r"<Size>(\d+)</Size>", c)
            m = re.search(r"<LastModified>([^<]+)</LastModified>", c)
            if k:
                out[k.group(1)] = (int(s.group(1)) if s else 0, m.group(1) if m else "")
        t = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", xml)
        if not t:
            break
        token = t.group(1)
    return out


# --------------------------------------------------------------------------- the trace
STAGES = [
    ("app", "Tenant app"),
    ("agent", "OTel agent"),
    ("kafka", "Kafka"),
    ("gateway", "OTel gateway"),
    ("distributor", "Distributors"),
    ("ingesters", "Ingesters"),
    ("query", "Query path"),
    ("isolation", "Tenant isolation"),
    ("storage", "Object storage"),
    ("ruler", "Ruler"),
]
TRACES = {}
BUSY = threading.Lock()


class Trace:
    def __init__(self, tenant, message):
        self.id = uuid.uuid4().hex[:10]
        self.tenant, self.message = tenant, message
        self.t0 = time.time()
        self.sent_ns = None
        self.stages = {k: {"key": k, "title": t, "status": "pending", "summary": "", "details": [], "data": {}}
                       for k, t in STAGES}
        self.finished = False

    def ms(self):
        return int((time.time() - self.t0) * 1000)

    def start(self, k, summary=""):
        self.stages[k].update(status="running", summary=summary, started_ms=self.ms())

    def done(self, k, summary, details=None, data=None, status="done"):
        self.stages[k].update(status=status, summary=summary, ms=self.ms(),
                              details=details or self.stages[k]["details"], data=data or self.stages[k]["data"])

    def fail(self, k, why):
        self.stages[k].update(status="failed", summary=why, ms=self.ms())

    def view(self):
        return {"id": self.id, "tenant": self.tenant, "message": self.message, "finished": self.finished,
                "elapsed_ms": self.ms(), "stages": [self.stages[k] for k, _ in STAGES]}


def wait_for(fn, timeout, every=1.0):
    end = time.time() + timeout
    while time.time() < end:
        r = fn()
        if r:
            return r
        time.sleep(every)
    return None


def run(tr):
    T = tr.tenant
    try:
        # What the platform looks like right before the line exists.
        before = {
            "kafka": kafka_partitions(),
            "streams": per_pod("ingester", "loki_ingester_streams_created_total", tenant=T),
            "lines": per_pod("distributor", "loki_distributor_lines_received_total", tenant=T),
            "otlp": per_pod("agent", "otelcol_receiver_accepted_log_records", receiver="otlp"),
            "sent": per_pod("gateway", "otelcol_exporter_sent_log_records", exporter=f"otlp_http/{T}"),
        }
        try:
            before["chunks"] = set(s3_keys(f"{T}/"))
        except RuntimeError:
            before["chunks"] = None
        found = step_app(tr) and step_agent(tr, before)
        if found:
            rec = step_kafka(tr, before)
            if rec:
                step_gateway(tr, rec)
            replicas = step_ingesters(tr, before)
            step_distributor(tr, before)
            if replicas:
                step_query(tr)
                step_isolation(tr)
                slow = [threading.Thread(target=step_storage, args=(tr, before)),
                        threading.Thread(target=step_ruler, args=(tr,))]
                for t in slow:
                    t.start()
                for t in slow:
                    t.join()
        for k, _ in STAGES:
            if tr.stages[k]["status"] in ("pending", "running"):
                tr.done(k, "skipped: an earlier step did not complete", status="skipped")
    except Exception as e:  # keep the page alive, show what broke
        for k, _ in STAGES:
            if tr.stages[k]["status"] == "running":
                tr.fail(k, f"{type(e).__name__}: {e}")
    finally:
        tr.finished = True
        BUSY.release()


def step_app(tr):
    tr.start("app", "asking the app to send the line")
    status, r = http("POST", EMITTER.format(tenant=tr.tenant) + "/emit",
                     {"trace_id": tr.id, "message": tr.message}, {"Content-Type": "application/json"}, timeout=15)
    if status != 200 or not isinstance(r, dict) or r.get("otlp_status") not in (200, 202):
        tr.fail("app", f"the app could not send it: {r}")
        return False
    tr.sent_ns = r["sent_ns"]
    tr.app = r
    tr.done("app", f"{r['pod']} sent the line over OTLP to the agent on its node",
            [["Pod", f"{r['namespace']}/{r['pod']}"], ["Node", r["node"]],
             ["Line", f"trace {tr.id}: {tr.message}"], ["Stream (service.name)", f"trace-{tr.id}"],
             ["The app also claimed", "k8s.namespace.name = claimed-by-the-app (ignored, see the agent)"]])
    return True


def step_agent(tr, before):
    tr.start("agent", "waiting for the agent on the app's node to accept it")
    node = tr.app["node"]
    agents = [p for p in pods("app.kubernetes.io/name=otel-agent") if p["node"] == node]
    if not agents:
        tr.fail("agent", f"no OTel agent pod on node {node}")
        return False
    agent = agents[0]

    def accepted():
        now = total(scrape(agent, 8888), "otelcol_receiver_accepted_log_records", receiver="otlp")
        return now - before["otlp"].get(agent["name"], 0) >= 1 and now

    if not wait_for(accepted, 30):
        tr.fail("agent", f"{agent['name']} did not report the record (otelcol_receiver_accepted_log_records)")
        return False
    tr.done("agent", f"{agent['name']} (same node) took it, set tenant {tr.tenant}, wrote it to Kafka",
            [["Agent pod", agent["name"]], ["Node", node],
             ["Why this agent", "the otel-agent Service has internalTrafficPolicy: Local: an app always reaches the agent on its own node"],
             ["Who sent it", f"looked up the connection's source IP in Kubernetes: a pod in namespace {tr.tenant}"],
             ["Tenant", f"{tr.tenant} (from the namespace; the app's own claim was deleted)"],
             ["Masked", "card numbers, IBANs and bearer tokens, before anything leaves the node"],
             ["Next hop", "Kafka topic otel-logs, acks=all"]],
            {"agent": agent["name"], "node": node})
    return True


def step_kafka(tr, before):
    tr.start("kafka", "reading the topic through the Kafka bridge to find the record")
    group, inst = f"demo-tracer-{tr.id}", "c"
    hdr = {"Content-Type": "application/vnd.kafka.v2+json", "Accept": "application/vnd.kafka.v2+json"}
    st, r = http("POST", f"{BRIDGE}/consumers/{group}", {"name": inst, "format": "binary",
                 "auto.offset.reset": "earliest", "enable.auto.commit": False}, hdr)
    if st != 200:
        tr.fail("kafka", f"Kafka bridge not reachable ({st}: {r})")
        return None
    base = f"{BRIDGE}/consumers/{group}/instances/{inst}"
    found = None
    try:
        parts = sorted(before["kafka"]) or list(range(PARTITIONS))
        http("POST", f"{base}/assignments", {"partitions": [{"topic": TOPIC, "partition": p} for p in parts]}, hdr)
        offsets = [{"topic": TOPIC, "partition": p, "offset": before["kafka"].get(p, {}).get("end_offset", 0)}
                   for p in parts]
        http("POST", f"{base}/positions", {"offsets": offsets}, hdr)
        needle = f"trace {tr.id}".encode()
        end, seen = time.time() + 60, 0
        while time.time() < end and not found:
            st, recs = http("GET", f"{base}/records?timeout=1000&max_bytes=8000000",
                            headers={"Accept": "application/vnd.kafka.binary.v2+json"}, timeout=20)
            for rec in recs if isinstance(recs, list) else []:
                seen += 1
                value = base64.b64decode(rec.get("value") or b"")
                if needle in value:
                    found = {"partition": rec["partition"], "offset": rec["offset"], "bytes": len(value),
                             "key": base64.b64decode(rec.get("key") or b"").hex()[:16], "seen": seen}
                    break
    finally:
        http("DELETE", base, headers=hdr)
    if not found:
        tr.fail("kafka", "the record did not show up in otel-logs within 60 s")
        return None
    parts = kafka_partitions()
    info = parts.get(found["partition"], {})
    leader = broker_pod(info.get("leader")) if "leader" in info else None
    zones = node_zones()
    tr.done("kafka", f"partition {found['partition']}, offset {found['offset']}, "
                     f"leader {leader['name'] if leader else 'broker ' + str(info.get('leader'))}",
            [["Topic", TOPIC], ["Partition", f"{found['partition']} of {len(parts) or PARTITIONS}"],
             ["Offset", str(found["offset"])],
             ["Message key", f"{found['key']}… (hash of the resource attributes: the same pod always lands on the same partition, in order)"],
             ["Leader broker", f"{leader['name']} on {leader['node']}" + (f" ({zones.get(leader['node'])})" if leader and zones.get(leader['node']) else "") if leader else "?"],
             ["Copies", f"{info.get('isr', '?')} in sync of {info.get('replicas', '?')} replicas" + (
                 ": the agent got its OK once 2 had them (acks=all, min.insync.replicas 2)" if info.get("replicas", 0) >= 3 else "")],
             ["Records read to find it", str(found["seen"])]],
            {"partitions": {str(k): v for k, v in sorted(parts.items())}, "hit": found["partition"],
             "offset": found["offset"]})
    return found


def step_gateway(tr, rec):
    tr.start("gateway", "finding the gateway pod that owns the partition")
    P, O = rec["partition"], rec["offset"]

    def owner():
        assign, mine = {}, None
        for p in pods("app.kubernetes.io/name=otel-gateway"):
            for n, labels, v in scrape(p, 8888):
                if n == "otelcol_kafka_receiver_current_offset" and labels.get("topic") == TOPIC:
                    assign.setdefault(p["name"], []).append(int(labels["partition"]))
                    if int(labels["partition"]) == P and v >= O:
                        mine = p["name"]
        return mine and (mine, assign)

    r = wait_for(owner, 45)
    if not r:
        tr.fail("gateway", f"no gateway reported consuming partition {P} past offset {O} yet")
        return
    mine, assign = r
    tr.done("gateway", f"{mine} owns partition {P}: it routed the line to {tr.tenant}'s queue and pushed it to Loki",
            [["Consumer group", "otel-gateway: Kafka splits the partitions between the gateway pods (no load balancer)"],
             ["Partitions per pod", "; ".join(f"{k}: {sorted(v)}" for k, v in sorted(assign.items()))],
             ["This line", f"partition {P} → {mine}"],
             ["Route", f'resource.attributes["obs.tenant"] == "{tr.tenant}" → exporter otlp_http/{tr.tenant}'],
             ["Its own queue", f"a persistent queue for {tr.tenant} only: a slow tenant can't block the others"],
             ["To Loki", f"POST /otlp/v1/logs with X-Scope-OrgID: {tr.tenant}, via the loki-distributor Service"]],
            {"assignment": assign, "owner": mine, "partition": P})


def step_ingesters(tr, before):
    tr.start("ingesters", "waiting for the new stream to appear on the ingesters")
    tr.start("distributor", "counting this tenant's lines per distributor")
    T = tr.tenant

    want = min(3, len(before["streams"]) or 3)        # replication factor 3, or fewer ingesters

    def created():
        now = per_pod("ingester", "loki_ingester_streams_created_total", tenant=T)
        d = deltas(before["streams"], now)
        return d if len(d) >= want else None

    d = wait_for(created, 60, every=1.5) or deltas(before["streams"],
                                                   per_pod("ingester", "loki_ingester_streams_created_total", tenant=T))
    ring = {}
    for p in pods("app.kubernetes.io/name=loki,app.kubernetes.io/component=ingester"):
        ring.setdefault(ingester_zone(p["name"]), []).append({"name": p["name"], "node": p["node"],
                                                              "ready": p["ready"], "has": p["name"] in d})
    if not d:
        tr.fail("ingesters", "no ingester created the stream within 60 s")
        return None
    tr.done("ingesters", f"stored on {len(d)} ingesters: " + ", ".join(sorted(d)),
            [["Stream", f'{{k8s_namespace_name="{T}", service_name="trace-{tr.id}", ...}}'],
             ["How they were chosen", "the distributor hashes the stream's labels onto the ring and takes the next ingester in EACH zone"],
             ["Copies", f"{len(d)} (replication factor 3); the push is acknowledged once 2 have it"],
             ["Which", "; ".join(f"{z}: {', '.join(i['name'] for i in v if i['has']) or '-'}" for z, v in sorted(ring.items()))],
             ["Until", "flushed to object storage as a compressed chunk (stage 9)"]],
            {"ring": ring, "replicas": sorted(d)})
    return d


def step_distributor(tr, before):
    T = tr.tenant
    d = deltas(before["lines"], per_pod("distributor", "loki_distributor_lines_received_total", tenant=T))
    if not d:
        tr.fail("distributor", "no distributor counted lines for this tenant")
        return
    tr.done("distributor", f"{T}'s lines since you clicked: " + ", ".join(f"{k} {int(v)}" for k, v in sorted(d.items())),
            [["Load balancing", "the gateways reach Loki through the loki-distributor Service: Kubernetes spreads their connections over the distributor pods"],
             ["Lines from your tenant since the click", "; ".join(f"{k}: {int(v)}" for k, v in sorted(d.items()))],
             ["Your line", "one of those (the app's normal logs flow at the same time)"],
             ["Checks", f"{T}'s limits: rate, burst, stream count, line size → 429 for this tenant only if exceeded"],
             ["OTLP → Loki", "4 resource attributes become labels (cluster, namespace, container, service.name); the rest is structured metadata"]],
            {"lines": d})


def step_query(tr):
    tr.start("query", "querying through the read gateway as the tenant")
    T = tr.tenant
    names = {"query-frontend": ("loki_request_duration_seconds_count", {"route": "loki_api_v1_query_range"}),
             "query-scheduler": ("loki_query_scheduler_queue_duration_seconds_count", {}),
             "querier": ("loki_request_duration_seconds_count", {"route": "loki_api_v1_query_range"})}
    snap = {c: per_pod(c, n, **m) for c, (n, m) in names.items()}
    logql = f'{{service_name="trace-{tr.id}"}}'
    start, end = tr.sent_ns - 300 * 10**9, time.time_ns() + 60 * 10**9

    def hit():
        st, r = loki_query(T, logql, start, end)
        if st == 200 and isinstance(r, dict) and r.get("data", {}).get("result"):
            return r
        return None

    r = wait_for(hit, 30, every=2)
    if not r:
        tr.fail("query", f"the line was not found through view /{T}/ within 30 s")
        return
    after = {c: per_pod(c, n, **m) for c, (n, m) in names.items()}
    d = {c: deltas(snap[c], after[c]) for c in names}
    stats = r["data"].get("stats", {})
    summ, ing, store = stats.get("summary", {}), stats.get("ingester", {}), stats.get("querier", {}).get("store", {})
    stream = r["data"]["result"][0]
    line = stream["values"][0][1]
    tr.done("query", f"found by {', '.join(d['query-frontend']) or 'a frontend'}; "
                     f"{len(d['querier'])} querier(s) pulled the work; {ing.get('totalReached', 0)} ingesters asked",
            [["Read gateway", f"key for view /{T}/ accepted → it SETS X-Scope-OrgID: {T} (whatever the caller sends)"],
             ["Query frontend", ", ".join(d["query-frontend"]) or "-"],
             ["Split / shards", f"{summ.get('splits', 0)} time splits, {summ.get('shards', 0)} shards (results cache first)"],
             ["Scheduler queue", f"{', '.join(d['query-scheduler']) or '-'}; waited {summ.get('queueTime', 0):.4f} s in {T}'s queue"],
             ["Queriers that pulled work", "; ".join(f"{k} ({int(v)})" for k, v in sorted(d["querier"].items())) or "-"],
             ["Ingesters asked (recent data)", str(ing.get("totalReached", 0))],
             ["Chunks from object storage", str(store.get("totalChunksRef", 0))],
             ["Found", line],
             ["Labels", ", ".join(f"{k}={v}" for k, v in sorted(stream["stream"].items())
                                   if k in ("k8s_namespace_name", "service_name", "k8s_pod_name", "detected_level"))],
             ["Took", f"{summ.get('execTime', 0):.3f} s"]],
            {"frontends": d["query-frontend"], "schedulers": d["query-scheduler"], "queriers": d["querier"],
             "all_queriers": sorted(after["querier"]), "line": line})


def step_isolation(tr):
    tr.start("isolation", "asking the same question as the other tenants")
    T = tr.tenant
    logql = f'{{service_name="trace-{tr.id}"}}'
    start, end = tr.sent_ns - 300 * 10**9, time.time_ns() + 60 * 10**9
    rows, ok = [], True
    for view in [t for t in TENANTS if t != T] + ["platform"]:
        st, r = loki_query(view, logql, start, end)
        n = sum(len(s["values"]) for s in r["data"]["result"]) if st == 200 and isinstance(r, dict) else None
        expect = 1 if view == "platform" else 0
        ok = ok and n == expect
        rows.append({"view": view, "status": st, "lines": n, "expected": expect})
    other = next(t for t in TENANTS if t != T) if len(TENANTS) > 1 else "platform"
    st, _ = loki_query(T, logql, start, end, api_key=key(other))
    rows.append({"view": f"{T} with {other}'s key", "status": st, "lines": None, "expected": "refused"})
    ok = ok and st in (401, 403)
    tr.done("isolation", ("other tenants see nothing; admin (platform) sees it" if ok else "UNEXPECTED: check the details"),
            [[f"/{r['view']}/" if " " not in r["view"] else r["view"],
              f"HTTP {r['status']}, {r['lines'] if r['lines'] is not None else '-'} line(s) (expected {r['expected']})"] for r in rows],
            {"rows": rows}, status="done" if ok else "failed")


def step_storage(tr, before):
    tr.start("storage", "waiting for the ingesters to flush the chunk (the stream idles for ~1 min)")
    T = tr.tenant
    if before.get("chunks") is None:
        tr.fail("storage", "object storage listing not available")
        return
    sent_ms = tr.sent_ns // 10**6

    def flushed():
        new = {k: v for k, v in s3_keys(f"{T}/").items() if k not in before["chunks"]}
        for k, (size, modified) in new.items():
            m = re.match(rf"{re.escape(T)}/([0-9a-f]+)/([0-9a-f]+):([0-9a-f]+):([0-9a-f]+)$", k)
            if m:
                frm, thr = int(m.group(2), 16), int(m.group(3), 16)
                if frm - 5000 <= sent_ms <= thr + 5000 and thr - frm < 10000:
                    return k, size, modified, len(new)
        return None

    r = wait_for(flushed, 300, every=10)
    if not r:
        tr.fail("storage", "no chunk for this stream within 5 min (chunk_idle_period 1m + flush)")
        return
    k, size, modified, n = r
    tr.done("storage", f"chunk {k.split('/')[1][:8]}… written ({size} bytes)",
            [["Object", f"loki-chunks/{k}"],
             ["Key", "<tenant>/<stream fingerprint>/<from>:<through>:<checksum>: the tenant is the first folder"],
             ["When", f"{modified}: after the stream was idle for chunk_idle_period (1 min in the demo, 30 min in production)"],
             ["3 copies?", "the 3 ingesters flushed identical chunks under the same key: stored once"],
             ["Other new chunks for this tenant", str(n - 1)],
             ["From now on", "queries read it from here (through the chunks cache); the compactor applies retention"]],
            {"key": k, "size": size})


def step_ruler(tr):
    tr.start("ruler", "waiting for the ruler's next evaluation (once a minute, 30 s offset)")
    T = tr.tenant
    promql = f'obs:log_lines:rate1m{{service_name="trace-{tr.id}"}}[10m]'

    def recorded():
        st, r = prom_query(T, promql)
        res = r.get("data", {}).get("result") if st == 200 and isinstance(r, dict) else None
        return res or None

    res = wait_for(recorded, 240, every=10)
    if not res:
        tr.fail("ruler", "no recorded series within 4 min")
        return
    labels = res[0]["metric"]
    value = float(res[0]["values"][-1][1])
    others = []
    for view in [t for t in TENANTS if t != T]:
        st, r = prom_query(view, promql)
        n = len(r.get("data", {}).get("result") or []) if st == 200 and isinstance(r, dict) else None
        others.append(f"/{view}/: {n} series")
    tr.done("ruler", f"obs:log_lines:rate1m recorded for {T} (tenant=\"{labels.get('tenant')}\")",
            [["Recording rule", "sum by (namespace, service) (rate({...}[1m] offset 30s)), once a minute, per tenant"],
             ["Who runs it", "the Loki ruler, with its own querier (not the users' queues)"],
             ["Result", f"{value:.4f} lines/s, labels: " + ", ".join(f"{k}={v}" for k, v in sorted(labels.items()) if k != "__name__")],
             ["Stored in", "the metrics store (Prometheus), every series stamped tenant=<owner>"],
             ["Read back", f"through /{T}/prometheus/: the tenant guard adds tenant=~\"{T}\" to every query"],
             ["Other tenants' views", "; ".join(others)],
             ["Why", "dashboards and alerts read this small series instead of re-scanning logs"]],
            {"labels": labels, "value": value})


# --------------------------------------------------------------------------- topology
_RATES = {"t": 0, "lines": {}}


def topology():
    zones = node_zones()
    comps = []
    for key_, title, selector, _ in COMPONENTS:
        ps = pods(selector)
        comps.append({"key": key_, "title": title, "ready": sum(p["ready"] for p in ps), "total": len(ps),
                      "pods": [{"name": p["name"], "node": p["node"], "zone": zones.get(p["node"], ""),
                                "ready": p["ready"],
                                **({"logical_zone": ingester_zone(p["name"])} if key_ == "ingester" else {})}
                               for p in ps]})
    tenants = []
    for t in TENANTS:
        tenants.append({"id": t, "app": APPS.get(t, ""), "pods": [
            {"name": p["name"], "node": p["node"], "ready": p["ready"]}
            for p in pods("app.kubernetes.io/component=emitter", namespace=t)]})
    # Lines per second per tenant, from the distributors (two scrapes apart).
    now = {t: sum(per_pod("distributor", "loki_distributor_lines_received_total", tenant=t).values())
           for t in TENANTS + ["platform"]}
    dt = time.time() - _RATES["t"]
    rates = {t: max(0.0, (now[t] - _RATES["lines"].get(t, now[t])) / dt) for t in now} if _RATES["t"] else {}
    _RATES.update(t=time.time(), lines=now)
    return {"namespace": NS, "components": comps, "tenants": tenants, "rates": rates,
            "partitions": {str(k): v for k, v in sorted(kafka_partitions().items())}}


# --------------------------------------------------------------------------- live flow
class Flow:
    """Samples every hop's counters every 3 s while the page is open, and turns
    them into per-second rates per pod (and per tenant where Loki/OTel count it)."""

    def __init__(self):
        self.prev, self.snap, self.last_req, self.thread = None, {"ready": False}, 0, None
        self.ruler, self.ruler_t = {}, 0

    def get(self):
        self.last_req = time.time()
        if not self.thread or not self.thread.is_alive():
            self.thread = threading.Thread(target=self.loop, daemon=True)
            self.thread.start()
        return self.snap

    def loop(self):
        while time.time() - self.last_req < 60:
            try:
                self.sample()
            except Exception as e:  # keep sampling; show the error
                self.snap = dict(self.snap, error=f"{type(e).__name__}: {e}")
            time.sleep(3)

    def sample(self):
        owners = TENANTS + ["platform", "unassigned"]
        now, c = time.time(), {}          # counters: key → value
        info = {"agents": [], "gateways": [], "distributors": [], "ingesters": [], "partitions": {}}
        for p in pods("app.kubernetes.io/name=otel-agent"):
            s = scrape(p, 8888)
            c[("agent_in", p["name"])] = (total(s, "otelcol_receiver_accepted_log_records", receiver="file_log")
                                          + total(s, "otelcol_receiver_accepted_log_records", receiver="otlp"))
            c[("agent_out", p["name"])] = total(s, "otelcol_exporter_sent_log_records", exporter="kafka")
            info["agents"].append({"pod": p["name"], "node": p["node"]})
        exp = pods("strimzi.io/name=logs-kafka-exporter")
        for n, labels, v in (scrape(exp[0], 9404) if exp else []):
            if labels.get("topic") != TOPIC or "partition" not in labels:
                continue
            part = int(labels["partition"])
            if n == "kafka_topic_partition_current_offset":
                c[("kafka_in", part)] = v
            elif n == "kafka_topic_partition_leader":
                info["partitions"].setdefault(part, {})["leader"] = int(v)
            elif n == "kafka_consumergroup_lag" and labels.get("consumergroup") == "otel-gateway" and v >= 0:
                info["partitions"].setdefault(part, {})["lag"] = int(v)     # -1: nothing committed yet
        for p in pods("app.kubernetes.io/name=otel-gateway"):
            s = scrape(p, 8888)
            c[("gw_in", p["name"])] = total(s, "otelcol_receiver_accepted_log_records", receiver="kafka")
            for t in owners:
                c[("gw_out", p["name"], t)] = total(s, "otelcol_exporter_sent_log_records", exporter=f"otlp_http/{t}")
            parts = sorted({int(l["partition"]) for n, l, _ in s
                            if n == "otelcol_kafka_receiver_current_offset" and l.get("topic") == TOPIC})
            info["gateways"].append({"pod": p["name"], "node": p["node"], "partitions": parts})
        appends = {}
        for p in pods("app.kubernetes.io/name=loki,app.kubernetes.io/component=distributor"):
            s = scrape(p, 3100)
            for t in owners:
                c[("dist", p["name"], t)] = total(s, "loki_distributor_lines_received_total", tenant=t)
            for n, labels, v in s:
                if n == "loki_distributor_ingester_appends_total":
                    ip_ = labels.get("ingester", "").rsplit(":", 1)[0]
                    appends[ip_] = appends.get(ip_, 0) + v
            info["distributors"].append({"pod": p["name"], "node": p["node"]})
        for p in pods("app.kubernetes.io/name=loki,app.kubernetes.io/component=ingester"):
            c[("ing_push", p["name"])] = appends.get(p["ip"], 0)
            c[("ing_flush", p["name"])] = total(scrape(p, 3100), "loki_ingester_chunks_flushed_total")
            info["ingesters"].append({"pod": p["name"], "node": p["node"], "zone": ingester_zone(p["name"])})
        if now - self.ruler_t > 15:       # the ruler's view, ~1 min behind
            st, r = prom_query("platform", "sum by (tenant) (obs:log_lines:rate1m)")
            if st == 200 and isinstance(r, dict):
                self.ruler = {x["metric"].get("tenant", "?"): float(x["value"][1]) for x in r["data"]["result"]}
            self.ruler_t = now
        rate = {}
        if self.prev:
            dt = max(0.5, now - self.prev[0])
            rate = {k: max(0.0, (v - self.prev[1].get(k, v)) / dt) for k, v in c.items()}
        self.prev = (now, c)
        r = lambda *k: round(rate.get(k, 0.0), 2)
        self.snap = {
            "ready": bool(rate), "t": now, "tenants": owners,
            "per_tenant": {t: round(sum(rate.get(("dist", d["pod"], t), 0) for d in info["distributors"]), 2) for t in owners},
            "agents": [dict(a, lines_in=r("agent_in", a["pod"]), to_kafka=r("agent_out", a["pod"])) for a in info["agents"]],
            "kafka": [{"partition": p, "messages": r("kafka_in", p), **info["partitions"].get(p, {})}
                      for p in sorted({k[1] for k in c if k[0] == "kafka_in"})],
            "gateways": [dict(g, lines_in=r("gw_in", g["pod"]), by_tenant={t: r("gw_out", g["pod"], t) for t in owners})
                         for g in info["gateways"]],
            "distributors": [dict(d, by_tenant={t: r("dist", d["pod"], t) for t in owners}) for d in info["distributors"]],
            "ingesters": [dict(i, pushes=r("ing_push", i["pod"]), flushes_per_min=round(60 * rate.get(("ing_flush", i["pod"]), 0), 1))
                          for i in info["ingesters"]],
            "ruler": self.ruler,
        }


FLOW = Flow()


def start_load(tenant, rate, seconds, via):
    status, r = http("POST", EMITTER.format(tenant=tenant) + "/burst",
                     {"lines_per_second": rate, "seconds": seconds, "via": via},
                     {"Content-Type": "application/json"}, timeout=10)
    return status, r


# --------------------------------------------------------------------------- web
class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            return self._send(200, open(os.path.join(HERE, "index.html"), "rb").read(), "text/html; charset=utf-8")
        if self.path == "/healthz":
            return self._send(200, {"ok": True})
        if self.path == "/api/topology":
            return self._send(200, topology())
        if self.path == "/api/flow":
            return self._send(200, FLOW.get())
        if self.path == "/api/info":
            return self._send(200, {"namespace": NS, "tenants": [{"id": t, "app": APPS.get(t, "")} for t in TENANTS],
                                    "grafana": os.environ.get("GRAFANA_HINT", ""), "busy": BUSY.locked()})
        m = re.match(r"^/api/trace/([0-9a-f]+)$", self.path)
        if m and m.group(1) in TRACES:
            return self._send(200, TRACES[m.group(1)].view())
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path not in ("/api/trace", "/api/load"):
            return self._send(404, {"error": "not found"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except ValueError:
            return self._send(400, {"error": "JSON body expected"})
        tenant = req.get("tenant")
        if tenant not in TENANTS:
            return self._send(400, {"error": f"tenant must be one of {TENANTS}"})
        if self.path == "/api/load":
            try:
                rate = max(1, min(500, int(req.get("lines_per_second", 50))))
                seconds = max(5, min(300, int(req.get("seconds", 60))))
            except (TypeError, ValueError):
                return self._send(400, {"error": "lines_per_second and seconds must be numbers"})
            status, r = start_load(tenant, rate, seconds, "otlp" if req.get("via") == "otlp" else "stdout")
            return self._send(200 if status == 200 else 502, r if isinstance(r, dict) else {"error": str(r)})
        if not BUSY.acquire(blocking=False):
            return self._send(409, {"error": "a trace is already running: wait for it to finish"})
        tr = Trace(tenant, str(req.get("message") or "hello from the demonstrator")[:200])
        TRACES[tr.id] = tr
        threading.Thread(target=run, args=(tr,), daemon=True).start()
        self._send(200, {"id": tr.id})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"log flow demonstrator on :{port} (namespace {NS}, tenants {TENANTS})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()

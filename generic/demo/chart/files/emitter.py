"""A tenant's demo app. Python standard library only.

1. Logs like a real service: a line to stdout every few seconds (the kubelet
   writes it to /var/log/pods; the OTel agent on this node reads it). Some lines
   carry a card number or an IBAN, to show the agent's masking.
2. POST /burst {"lines_per_second", "seconds", "via"}: extra workload on
   demand (the demonstrator's "Generate workload"). via=stdout (like most
   apps) or via=otlp (like apps with an OpenTelemetry SDK, batched).
3. POST /emit {"trace_id", "message"}: sends ONE traced line the way an app
   with an OpenTelemetry SDK does, over OTLP/HTTP to the agent on this node
   (otel-agent Service, internalTrafficPolicy Local). service.name is
   trace-<id>, so the line starts a brand-new Loki stream the demonstrator
   can follow.
"""
import json
import os
import random
import sys
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP = os.environ.get("APP", "app")
POD = os.environ.get("POD_NAME", "local")
NODE = os.environ.get("NODE_NAME", "local")
NAMESPACE = os.environ.get("POD_NAMESPACE", "local")
AGENT = os.environ.get("OTEL_AGENT_URL", "http://otel-agent:4318/v1/logs")

MESSAGES = {
    "payments": [
        ("info", 'msg="payment authorised" amount={amt} card=4111111111111111'),
        ("info", 'msg="refund issued" amount={amt} iban=DE89370400440532013000'),
        ("warn", 'msg="3-D Secure challenge timed out, retrying" attempt=2'),
        ("error", 'msg="payment declined by issuer" reason=insufficient_funds'),
    ],
    "orders": [
        ("info", 'msg="order created" items={n} total={amt}'),
        ("info", 'msg="order shipped" carrier=DHL'),
        ("warn", 'msg="stock reservation slow" duration_ms={ms}'),
        ("error", 'msg="order rejected" reason=address_invalid'),
    ],
    "inventory": [
        ("info", 'msg="stock level updated" sku=SKU-{n} quantity={n}'),
        ("info", 'msg="nightly reconciliation chunk done" rows={ms}'),
        ("warn", 'msg="supplier feed late" minutes={n}'),
        ("error", 'msg="warehouse sync failed" warehouse=WH-{n}'),
    ],
}


def log(level, text):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"ts={ts} level={level} app={APP} {text}", flush=True)


def realistic():
    level, tmpl = random.choices(MESSAGES.get(APP, MESSAGES["orders"]), weights=[50, 30, 12, 8])[0]
    return level, tmpl.format(amt=f"{random.uniform(5, 500):.2f}", n=random.randint(1, 99),
                              ms=random.randint(100, 5000))


def background():
    while True:
        log(*realistic())
        time.sleep(random.uniform(2, 5))


BURST = {"id": None, "until": 0, "rate": 0, "via": "", "sent": 0}


def burst(burst_id, rate, seconds, via):
    """rate lines/s for seconds, to stdout or as OTLP batches (one request per 0.5 s)."""
    start, n, batch = time.time(), 0, []
    BURST.update(id=burst_id, until=start + seconds, rate=rate, via=via, sent=0)
    while time.time() < start + seconds and BURST["id"] == burst_id:
        due = int((time.time() - start) * rate)
        while n < due:
            level, text = realistic()
            text += f" burst={burst_id}"
            if via == "otlp":
                batch.append((level, text))
            else:
                log(level, text)
            n += 1
        if via == "otlp" and batch:
            try:
                send_records(batch)
            except Exception as e:
                log("warn", f'msg="burst batch failed" error="{e}"')
            batch = []
        BURST["sent"] = n
        time.sleep(0.5 if via == "otlp" else 0.02)


def send_records(records, service=None, attrs=None):
    """records: [(severity, body)] in ONE OTLP request; returns the HTTP status."""
    now = time.time_ns()
    body = {"resourceLogs": [{
        "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service or APP}}]
                     + [{"key": k, "value": {"stringValue": v}} for k, v in (attrs or {}).items()]},
        "scopeLogs": [{"logRecords": [{"timeUnixNano": str(now + i), "severityText": sev.upper(),
                                       "body": {"stringValue": text}} for i, (sev, text) in enumerate(records)]}],
    }]}
    req = urllib.request.Request(AGENT, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def send_otlp(trace_id, message):
    now = time.time_ns()
    body = {"resourceLogs": [{
        "resource": {"attributes": [
            {"key": "service.name", "value": {"stringValue": f"trace-{trace_id}"}},
            # Claims the app makes about itself. The agent DELETES these and asks
            # Kubernetes which pod opened the connection instead.
            {"key": "k8s.namespace.name", "value": {"stringValue": "claimed-by-the-app"}},
        ]},
        "scopeLogs": [{"logRecords": [{
            "timeUnixNano": str(now),
            "severityText": "INFO",
            "body": {"stringValue": f"trace {trace_id}: {message}"},
            "attributes": [
                {"key": "trace.id", "value": {"stringValue": trace_id}},
                {"key": "app", "value": {"stringValue": APP}},
            ],
        }]}],
    }]}
    req = urllib.request.Request(AGENT, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return now, r.status


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        active = BURST["id"] and time.time() < BURST["until"]
        self._json(200, {"app": APP, "pod": POD, "node": NODE, "namespace": NAMESPACE,
                         "burst": {k: BURST[k] for k in ("id", "rate", "via", "sent")} | {"active": bool(active),
                                   "seconds_left": max(0, int(BURST["until"] - time.time()))}})

    def do_POST(self):
        if self.path == "/burst":
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                rate = max(1, min(500, int(req.get("lines_per_second", 50))))
                seconds = max(5, min(300, int(req.get("seconds", 60))))
                via = "otlp" if req.get("via") == "otlp" else "stdout"
            except (ValueError, TypeError) as e:
                return self._json(400, {"error": str(e)})
            burst_id = uuid.uuid4().hex[:6]
            threading.Thread(target=burst, args=(burst_id, rate, seconds, via), daemon=True).start()
            log("info", f'msg="workload burst started" burst={burst_id} lines_per_second={rate} seconds={seconds} via={via}')
            return self._json(200, {"burst": burst_id, "lines_per_second": rate, "seconds": seconds, "via": via,
                                    "lines": rate * seconds, "pod": POD, "node": NODE})
        if self.path != "/emit":
            return self._json(404, {"error": "POST /emit or /burst"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            trace_id = "".join(c for c in str(req["trace_id"]) if c.isalnum())[:32]
            message = str(req.get("message") or "hello")[:300]
            sent_ns, status = send_otlp(trace_id, message)
            log("info", f'msg="sent traced line over OTLP" trace={trace_id}')
            self._json(200, {"pod": POD, "node": NODE, "namespace": NAMESPACE, "app": APP,
                             "sent_ns": sent_ns, "otlp_status": status, "agent": AGENT})
        except Exception as e:  # report to the demonstrator, keep serving
            self._json(500, {"error": f"{type(e).__name__}: {e}", "pod": POD, "node": NODE})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=background, daemon=True).start()
    log("info", f'msg="started" pod={POD} node={NODE}')
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()

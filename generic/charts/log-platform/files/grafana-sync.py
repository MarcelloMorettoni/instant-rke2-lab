"""Keep Grafana in step with the tenant registry (runs as a CronJob).

For every entry in /config/orgs.json:
  - ensure a Grafana org named after the view (the tenant id, or "platform");
  - ensure ONE Loki data source (uid loki-<view>) pointing at that view on the
    read gateway, with the view's current key from Key Vault (/keys/obs-key-<view>).
Users are not created here: Entra ID group membership maps them to orgs.
Idempotent. Never prints a key. Exits non-zero if any org failed.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

GRAFANA = os.environ.get("GRAFANA_URL", "http://grafana.grafana.svc.cluster.local")
GATEWAY = os.environ.get("READ_GATEWAY", "http://obs-gateway.loki.svc.cluster.local:8080")
AUTH = "Basic " + base64.b64encode(
    f'{os.environ["GF_ADMIN_USER"]}:{os.environ["GF_ADMIN_PASSWORD"]}'.encode()).decode()


def api(method, path, body=None, org=None):
    req = urllib.request.Request(GRAFANA + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", AUTH)
    req.add_header("Content-Type", "application/json")
    if org:
        req.add_header("X-Grafana-Org-Id", str(org))
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, {}


def wait_for_grafana():
    for _ in range(60):
        try:
            if api("GET", "/api/health")[0] == 200:
                return
        except OSError:
            pass
        time.sleep(5)
    sys.exit("grafana not reachable")


def main():
    wait_for_grafana()
    orgs = json.load(open("/config/orgs.json"))
    failed = 0
    for o in orgs:
        view = o["view"]
        key_file = f"/keys/obs-key-{view}"
        if not os.path.exists(key_file):
            print(f"org {view}: no key yet (obs-key-{view} in Key Vault? External Secrets synced?)")
            failed += 1
            continue
        key = open(key_file).read().strip()
        status, body = api("GET", f"/api/orgs/name/{view}")
        org = body.get("id") if status == 200 else None
        if not org:
            status, body = api("POST", "/api/orgs", {"name": view})
            org = body.get("orgId")
        if not org:
            print(f"org {view}: cannot create (HTTP {status})")
            failed += 1
            continue
        ds = {"name": "Loki", "uid": f"loki-{view}", "type": "loki", "access": "proxy",
              "url": f"{GATEWAY}/{view}", "isDefault": True, "basicAuth": False,
              "jsonData": {"httpHeaderName1": "X-Api-Key", "maxLines": 5000, "timeout": 300},
              "secureJsonData": {"httpHeaderValue1": key}}
        exists = api("GET", f"/api/datasources/uid/loki-{view}", org=org)[0] == 200
        status, _ = (api("PUT", f"/api/datasources/uid/loki-{view}", ds, org) if exists
                     else api("POST", "/api/datasources", ds, org))
        if status >= 400:
            print(f"org {view}: data source update failed (HTTP {status})")
            failed += 1
            continue
        print(f"org {view} (id {org}): Loki -> {GATEWAY}/{view} [{', '.join(o['tenants'])}]")
    status, main_ds = api("GET", "/api/datasources", org=1)
    if status == 200 and main_ds:
        print(f"WARNING: Main Org has {len(main_ds)} data source(s); unmapped logins land there")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

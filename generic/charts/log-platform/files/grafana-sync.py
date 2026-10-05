"""Keep Grafana in step with the tenant registry (runs as a CronJob).

For every entry in /config/orgs.json:
  - ensure a Grafana org named after the view (the tenant id, or "platform");
  - ensure ONE Loki data source (uid loki-<view>) pointing at that view on the
    read gateway, with the view's current key (/keys/obs-key-<view>);
  - with RECORDED_METRICS=true, also ONE Prometheus data source (uid metrics-<view>)
    for the ruler's recorded metrics, through the same view and key
    (<view>/prometheus: the gateway's tenant guard limits it to the view's tenants).
Local people (/config/users.json):
  - the admin (every mode): created once with its INITIAL password, made Grafana
    server admin and Admin of the platform org (every tenant);
  - the mock users (auth.provider: disabled): created once with their initial
    password, each a member of exactly its own org.
Passwords are set ONLY when a user is created, never reset: a password someone
changed in Grafana stays changed. SSO users are mapped to orgs by group at login.
This job signs in as the automation account (GF_ADMIN_*), not as the admin, so
changing the admin's password never breaks it.
Idempotent. Never prints a key or a password. Exits non-zero if anything failed.
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
RECORDED_METRICS = os.environ.get("RECORDED_METRICS", "false").lower() == "true"
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


def org_id(name):
    status, body = api("GET", f"/api/orgs/name/{name}")
    return body.get("id") if status == 200 else None


def initial_password(login):
    for path in (f"/local/{login}", "/breakglass/password"):
        if os.path.exists(path):
            return open(path).read().strip()
    return None


def ensure_user(login, org=None):
    """Create the user if missing (with its initial password). Returns its id."""
    status, body = api("GET", f"/api/users/lookup?loginOrEmail={login}")
    if status == 200:
        return body.get("id"), False
    password = initial_password(login)
    if not password:
        print(f"user {login}: no initial password (Secret grafana-local-users / grafana-breakglass)")
        return None, False
    body = {"name": login, "login": login, "email": f"{login}@local", "password": password}
    if org:
        body["OrgId"] = org
    status, body = api("POST", "/api/admin/users", body)
    return body.get("id"), True


def set_membership(uid, login, org, role, only=False):
    if api("POST", f"/api/orgs/{org}/users", {"loginOrEmail": login, "role": role})[0] >= 400:
        api("PATCH", f"/api/orgs/{org}/users/{uid}", {"role": role})
    api("POST", f"/api/users/{uid}/using/{org}")
    if only and org != 1:
        api("DELETE", f"/api/orgs/1/users/{uid}")


def sync_local_users():
    """The admin and the mock users. Returns the number of failures."""
    try:
        local = json.load(open("/config/users.json"))
    except (OSError, ValueError):
        return 0
    failed = 0
    for u in local.get("users") or []:
        login, org_name, role = u["login"], u["org"], u["role"]
        org = org_id(org_name)
        uid, created = ensure_user(login, org)
        if not (uid and org):
            print(f"mock user {login}: failed (org {org_name} exists: {bool(org)})")
            failed += 1
            continue
        set_membership(uid, login, org, role, only=True)
        print(f"mock user {login}: {role} in org {org_name}{' (created)' if created else ''}")
    admin = local.get("admin")
    if admin:
        uid, created = ensure_user(admin)
        platform = org_id("platform")
        if not (uid and platform):
            print(f"admin {admin}: failed")
            return failed + 1
        api("PUT", f"/api/admin/users/{uid}/permissions", {"isGrafanaAdmin": True})
        set_membership(uid, admin, platform, "Admin")
        print(f"admin {admin}: server admin, Admin in org platform{' (created)' if created else ''}")
    return failed


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
        sources = [{"name": "Loki", "uid": f"loki-{view}", "type": "loki", "access": "proxy",
                    "url": f"{GATEWAY}/{view}", "isDefault": True, "basicAuth": False,
                    "jsonData": {"httpHeaderName1": "X-Api-Key", "maxLines": 5000, "timeout": 300},
                    "secureJsonData": {"httpHeaderValue1": key}}]
        if RECORDED_METRICS:
            sources.append({"name": "Log metrics (recorded)", "uid": f"metrics-{view}", "type": "prometheus",
                            "access": "proxy", "url": f"{GATEWAY}/{view}/prometheus", "isDefault": False,
                            "basicAuth": False,
                            "jsonData": {"httpHeaderName1": "X-Api-Key", "httpMethod": "POST",
                                         "timeInterval": "1m", "prometheusType": "Prometheus",
                                         "timeout": 120},
                            "secureJsonData": {"httpHeaderValue1": key}})
        bad = False
        for ds in sources:
            exists = api("GET", f"/api/datasources/uid/{ds['uid']}", org=org)[0] == 200
            status, _ = (api("PUT", f"/api/datasources/uid/{ds['uid']}", ds, org) if exists
                         else api("POST", "/api/datasources", ds, org))
            if status >= 400:
                print(f"org {view}: data source {ds['name']} update failed (HTTP {status})")
                bad = True
        if bad:
            failed += 1
            continue
        print(f"org {view} (id {org}): {' + '.join(d['name'] for d in sources)} -> {GATEWAY}/{view} "
              f"[{', '.join(o['tenants'])}]")
    failed += sync_local_users()
    status, main_ds = api("GET", "/api/datasources", org=1)
    if status == 200 and main_ds:
        print(f"WARNING: Main Org has {len(main_ds)} data source(s); unmapped logins land there")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

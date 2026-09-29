#!/usr/bin/env python3
"""Render every tenant-specific object from tenants/tenants.yaml.

Usage:
    scripts/render-tenants.py                 # write rendered/*
    scripts/render-tenants.py --check         # validate the registry only
    scripts/render-tenants.py --which NS...   # which tenant does namespace NS map to?

Outputs (in rendered/, safe to commit: no secrets):
    values-tenants.yaml   values for charts/log-platform:
                            otelAgent.alternateConfig    namespace -> tenant (OTTL)
                            otelGateway.alternateConfig  routing + one exporter/queue per tenant
                            loki.loki.runtimeConfig      per-tenant limits + retention
                            readViews                    one read-gateway view per Grafana org
                            grafanaOrgs                  orgs + data sources (grafana-sync)
                            grafanaOrgMapping            Entra group -> org + role, allowed groups
    grafana-orgs.json     the same orgs, for scripts/tenant-keys.sh
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "tenants" / "tenants.yaml"
AGENT_TEMPLATE = ROOT / "collector" / "agent-config.yaml"
GATEWAY_TEMPLATE = ROOT / "collector" / "gateway-config.yaml"
LOKI_OTLP = "http://loki-distributor.loki.svc.cluster.local:3100/otlp"
OUT = ROOT / "rendered"

ID_RE = re.compile(r"^[a-z][a-z0-9-]{1,39}$")
GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
STATUSES = {"active", "suspended", "offboarding"}
RESERVED = {"platform", "unassigned"}



def die(msg: str) -> None:
    print(f"render-tenants: {msg}", file=sys.stderr)
    sys.exit(1)


def ns_regex(raw: str) -> str:
    """Folded YAML scalars add spaces between lines; a regex never needs them."""
    return re.sub(r"\s+", "", raw)


def load() -> dict:
    reg = yaml.safe_load(REGISTRY.read_text())
    tiers = reg.get("tiers") or {}
    seen: set[str] = set()

    def check_groups(owner: str, groups: dict | None) -> None:
        for role in ("viewer", "editor"):
            gid = (groups or {}).get(role)
            if gid and not GUID_RE.match(str(gid)):
                die(f"{owner}: entraGroups.{role} must be an Entra object ID (GUID), got {gid!r}")

    for name, tier in tiers.items():
        if not isinstance(tier.get("loki"), dict) or not isinstance(tier.get("gatewayQueueMiB"), int):
            die(f"tier {name}: needs `loki:` (limits) and `gatewayQueueMiB:` (integer)")
    for key in ("platform", "unassigned"):
        if reg.get(key, {}).get("id") != key:
            die(f"`{key}.id` must be {key!r}")
        if reg[key].get("tier") not in tiers:
            die(f"{key}: unknown tier {reg[key].get('tier')!r}")
    check_groups("platform", reg["platform"].get("entraGroups"))
    re.compile(ns_regex(reg["platform"]["namespaces"]))

    for t in reg.get("tenants") or []:
        tid = t.get("id", "")
        if not ID_RE.match(tid):
            die(f"tenant id {tid!r} must match {ID_RE.pattern}")
        if tid in RESERVED or tid in seen:
            die(f"tenant id {tid!r} is reserved or duplicated")
        seen.add(tid)
        if t.get("tier") not in tiers:
            die(f"{tid}: unknown tier {t.get('tier')!r}")
        t.setdefault("status", "active")
        if t["status"] not in STATUSES:
            die(f"{tid}: status must be one of {sorted(STATUSES)}")
        try:
            re.compile(ns_regex(t["namespaces"]))
        except (KeyError, re.error) as e:
            die(f"{tid}: bad or missing namespaces regex: {e}")
        if '"' in t["namespaces"]:
            die(f"{tid}: namespaces regex must not contain double quotes")
        check_groups(tid, t.get("entraGroups"))
    for t in reg.get("tenants") or []:
        for other in t.get("alsoRead") or []:
            if other not in seen:
                die(f"{t['id']}: alsoRead names unknown tenant {other!r}")
    return reg


def tenant_for(reg: dict, namespace: str) -> str:
    """Same semantics as the agent's transform/tenant statements: full match, last match wins."""
    result = reg["unassigned"]["id"]
    if re.fullmatch(ns_regex(reg["platform"]["namespaces"]), namespace):
        result = "platform"
    for t in reg["tenants"]:
        if re.fullmatch(ns_regex(t["namespaces"]), namespace):
            result = t["id"]
    return result


# --------------------------------------------------------------------------- OTel
def ottl_string(v: str) -> str:
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


def owners(reg: dict) -> list[dict]:
    """Every Loki tenant that receives data: platform, unassigned, all tenants.
    Suspended and offboarding tenants still receive (and keep) their logs."""
    return [reg["platform"], reg["unassigned"], *reg["tenants"]]


def render_otel_agent(reg: dict) -> dict:
    cfg = yaml.safe_load(AGENT_TEMPLATE.read_text())
    ns = 'resource.attributes["k8s.namespace.name"]'
    statements = [f'set(resource.attributes["obs.tenant"], {ottl_string(reg["unassigned"]["id"])})']
    for tid, regex in [("platform", reg["platform"]["namespaces"])] + [
            (t["id"], t["namespaces"]) for t in reg["tenants"]]:
        statements.append(
            f'set(resource.attributes["obs.tenant"], {ottl_string(tid)}) '
            f'where {ns} != nil and IsMatch({ns}, {ottl_string("^(" + ns_regex(regex) + ")$")})')
    cfg["processors"]["transform/tenant"]["log_statements"][0]["statements"] = statements
    return cfg


def render_otel_gateway(reg: dict) -> dict:
    cfg = yaml.safe_load(GATEWAY_TEMPLATE.read_text())
    table, exporters = [], {}
    for o in owners(reg):
        tid = o["id"]
        if tid != reg["unassigned"]["id"]:
            table.append({"condition": f'resource.attributes["obs.tenant"] == {ottl_string(tid)}',
                          "pipelines": [f"logs/{tid}"]})
        exporters[f"otlp_http/{tid}"] = {
            "endpoint": LOKI_OTLP,
            "headers": {"X-Scope-OrgID": tid},
            "compression": "gzip",
            "timeout": "30s",
            # This tenant's own durable queue on the gateway pod's disk.
            "sending_queue": {
                "enabled": True,
                "storage": "file_storage",
                "sizer": "bytes",
                "queue_size": reg["tiers"][o["tier"]]["gatewayQueueMiB"] * 1024 * 1024,
                "num_consumers": 4,
                "batch": {"flush_timeout": "1s", "sizer": "bytes",
                          "min_size": 1048576, "max_size": 4194304},
            },
            # Loki down or the tenant throttled (429): keep retrying from the
            # queue for up to 6 h, then drop (counted, alerted).
            "retry_on_failure": {"enabled": True, "initial_interval": "1s",
                                 "max_interval": "60s", "max_elapsed_time": "6h"},
        }
        cfg["service"]["pipelines"][f"logs/{tid}"] = {
            "receivers": ["routing"],
            "processors": ["resource/internal"],
            "exporters": [f"otlp_http/{tid}"],
        }
    cfg["connectors"]["routing"]["table"] = table
    cfg["exporters"] = exporters
    return cfg


# --------------------------------------------------------------------------- Loki
def render_overrides(reg: dict) -> dict:
    tiers = reg["tiers"]
    overrides = {}
    for owner in [reg["platform"], reg["unassigned"], *reg["tenants"]]:
        limits = dict(tiers[owner["tier"]]["loki"])
        limits.update(owner.get("limits") or {})
        if owner.get("status") == "offboarding":
            limits["retention_period"] = "24h"
        overrides[owner["id"]] = limits
    return overrides


# --------------------------------------------------------------------------- views
def readable_tenants(reg: dict) -> dict[str, list[str]]:
    """view -> list of Loki tenants that view's Grafana org may read."""
    live = [t for t in reg["tenants"] if t["status"] != "offboarding"]
    views = {}
    for t in reg["tenants"]:
        if t["status"] != "active":
            continue                      # suspended/offboarding: nobody reads through a tenant view
        views[t["id"]] = [t["id"], *[o for o in (t.get("alsoRead") or [])]]
    views["platform"] = ["platform", reg["unassigned"]["id"], *[t["id"] for t in live]]
    return views


# --------------------------------------------------------------------------- Grafana
def render_grafana(reg: dict) -> tuple[list[dict], dict]:
    views = readable_tenants(reg)
    orgs, mapping, groups_allowed = [], [], []
    owners = [{"id": "platform", "name": "Platform", **reg["platform"]}] + [
        t for t in reg["tenants"] if t["id"] in views
    ]
    for o in owners:
        orgs.append({"org": o["id"], "title": o.get("name", o["id"]),
                     "view": o["id"], "tenants": views[o["id"]]})
        groups = o.get("entraGroups") or {}
        if groups.get("viewer"):
            mapping.append(f"{groups['viewer']}:{o['id']}:Viewer")
            groups_allowed.append(groups["viewer"])
        if groups.get("editor"):
            mapping.append(f"{groups['editor']}:{o['id']}:Editor")
            groups_allowed.append(groups["editor"])
    # Grafana [auth.azuread] org_mapping and allowed_groups: only members of a
    # mapped group may log in at all.
    return orgs, {"orgMapping": " ".join(mapping), "allowedGroups": " ".join(groups_allowed)}


# --------------------------------------------------------------------------- main
HEADER = "# GENERATED by scripts/render-tenants.py from tenants/tenants.yaml. Do not edit.\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="validate tenants.yaml, write nothing")
    ap.add_argument("--which", nargs="+", metavar="NS", help="print the tenant of each namespace")
    args = ap.parse_args()

    reg = load()
    if args.which:
        for ns in args.which:
            print(f"{ns}\t{tenant_for(reg, ns)}")
        return
    if args.check:
        print(f"ok: {len(reg['tenants'])} tenants")
        return

    OUT.mkdir(exist_ok=True)
    for old in ("otel-agent-values.yaml", "otel-gateway-values.yaml", "loki-tenants-values.yaml",
                "gateway-views.yaml", "grafana-org-mapping.yaml"):
        (OUT / old).unlink(missing_ok=True)                   # pre-chart outputs
    orgs, mapping = render_grafana(reg)
    values = {
        "otelAgent": {"alternateConfig": render_otel_agent(reg)},
        "otelGateway": {"alternateConfig": render_otel_gateway(reg)},
        "loki": {"loki": {"runtimeConfig": {"overrides": render_overrides(reg)}}},
        "readViews": [{"view": v, "tenants": t} for v, t in readable_tenants(reg).items()],
        "grafanaOrgs": orgs,
        "grafanaOrgMapping": mapping,
    }
    (OUT / "values-tenants.yaml").write_text(HEADER + yaml.safe_dump(values, sort_keys=False, width=200))
    (OUT / "grafana-orgs.json").write_text(json.dumps(orgs, indent=2) + "\n")
    views = readable_tenants(reg)
    print(f"rendered {len(reg['tenants'])} tenants, {len(views)} read views -> {OUT.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()

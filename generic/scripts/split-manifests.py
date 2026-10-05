#!/usr/bin/env python3
"""Split `helm template` output into one file per platform component.

    split-manifests.py --env NAME --out DIR [--overlays FILE] OPERATORS.yaml PLATFORM.yaml

Used by scripts/render-manifests.sh. Secret data is redacted; CRDs are only
listed (in DIR/README.md).
"""
from __future__ import annotations

import argparse
import shutil
from collections import defaultdict
from pathlib import Path

import yaml

REDACTED = "REDACTED"

# (file, title, what it is) in install order.
OPERATORS = {
    "00-namespaces": "Namespaces loki, kafka, keycloak; Gateway API upgrade guard",
    "10-kgateway": "kgateway controller (Gateway API): read gateway and the Grafana/Keycloak load balancer",
    "20-strimzi": "Strimzi Kafka operator (watches namespace kafka)",
    "30-keycloak-operator": "Keycloak operator (namespace keycloak)",
    "40-external-secrets": "External Secrets Operator (Key Vault, Workload Identity)",
    "99-other": "Anything not matched above",
}
PLATFORM = {
    "00-namespaces-and-classes": "Namespaces otel, otel-agent, grafana; priority classes; storage class",
    "10-kafka": "Kafka cluster logs (KRaft), topic otel-logs, users otel-agent/otel-gateway, listener TLS, client Secrets",
    "20-otel-agent": "OTel agent DaemonSet: reads node logs + OTLP, sets the tenant, masks, writes to Kafka",
    "21-otel-gateway": "OTel gateway StatefulSet: consumes Kafka, one queue + Loki exporter per tenant",
    "30-loki-write": "Loki distributors and zone-aware ingesters (zone a/b/c)",
    "31-loki-read": "Loki query-frontend, query-scheduler, queriers, index gateways",
    "32-loki-backend": "Loki compactor (retention, deletes) and overrides exporter",
    "33-loki-caches": "Memcached: chunks cache and results cache",
    "34-loki-shared": "Loki config, runtime overrides (per-tenant limits), memberlist, rollout-operator",
    "40-read-gateway": "Read gateway (kgateway): one view per Grafana org, keys, read-only rules",
    "50-grafana": "Grafana (orgs per tenant), sign-in settings, grafana-sync CronJob, database Secret",
    "51-ingress": "Internal load balancer for Grafana (and Keycloak): Gateway, TLS",
    "60-keycloak": "Keycloak server and realm obs (groups, grafana client, users, Entra broker)",
    "70-secret-store": "Key Vault ClusterSecretStore (External Secrets)",
    "80-network-policies": "NetworkPolicies (and Cilium policies) for every platform namespace",
    "90-monitoring": "PodMonitors and the PrometheusRule (alerts)",
    "99-other": "Anything not matched above",
}
LOKI = {
    "distributor": "30-loki-write", "ingester": "30-loki-write",
    "query-frontend": "31-loki-read", "query-scheduler": "31-loki-read",
    "querier": "31-loki-read", "index-gateway": "31-loki-read",
    "compactor": "32-loki-backend", "overrides-exporter": "32-loki-backend",
    "memcached-chunks-cache": "33-loki-caches", "memcached-results-cache": "33-loki-caches",
}
GATEWAY_KINDS = {"Gateway", "GatewayParameters", "HTTPRoute", "TrafficPolicy", "DirectResponse", "ListenerPolicy"}


def operator_component(d: dict) -> str:
    kind, m = d["kind"], d["metadata"]
    name, ns = m["name"], m.get("namespace") or ""
    if kind in ("Namespace", "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"):
        return "00-namespaces"
    if "kgateway" in name:
        return "10-kgateway"
    if "strimzi" in name:
        return "20-strimzi"
    if "keycloak" in name or ns == "keycloak":
        return "30-keycloak-operator"
    if "external-secrets" in name or ns == "external-secrets" or kind == "ValidatingWebhookConfiguration":
        return "40-external-secrets"
    return "99-other"


def platform_component(d: dict) -> str:
    kind, m = d["kind"], d["metadata"]
    name, ns = m["name"], m.get("namespace") or ""
    labels = m.get("labels") or {}
    comp = labels.get("app.kubernetes.io/component", "")
    if kind in ("NetworkPolicy", "CiliumNetworkPolicy"):
        return "80-network-policies"
    if kind in ("PodMonitor", "PrometheusRule"):
        return "90-monitoring"
    if kind in ("Namespace", "PriorityClass", "StorageClass"):
        return "00-namespaces-and-classes"
    if kind == "ClusterSecretStore":
        return "70-secret-store"
    if ns == "kafka" or name == "kafka-client":
        return "10-kafka"
    if ns == "otel-agent" or name == "otel-agent":
        return "20-otel-agent"
    if ns == "otel":
        return "21-otel-gateway"
    if ns == "keycloak" or name == "keycloak-tls":
        return "60-keycloak"
    if ns == "grafana":
        if name in ("grafana-ingress", "grafana-tls") or (kind == "HTTPRoute" and name == "grafana"):
            return "51-ingress"
        return "50-grafana"
    if ns == "loki":
        if kind in GATEWAY_KINDS or name.startswith("obs-key-"):
            return "40-read-gateway"
        if comp in LOKI:
            return LOKI[comp]
        return "34-loki-shared"
    if "rollout-operator" in name or comp == "rollout-operator" or name.endswith("-loki"):
        return "34-loki-shared"
    return "99-other"


def redact(d: dict) -> dict:
    if d["kind"] == "Secret":
        for key in ("data", "stringData"):
            if d.get(key):
                d[key] = {k: REDACTED for k in d[key]}
    return d


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--overlays", default="")
    ap.add_argument("operators")
    ap.add_argument("platform")
    a = ap.parse_args()

    out = Path(a.out)
    if out.exists():
        shutil.rmtree(out)
    overlays = []
    if a.overlays and Path(a.overlays).exists():
        overlays = [line.strip() for line in Path(a.overlays).read_text().splitlines()
                    if line.strip() and not line.startswith("#")]
    crds: list[str] = []
    index = []
    for part, path, titles, classify in (("operators", a.operators, OPERATORS, operator_component),
                                         ("platform", a.platform, PLATFORM, platform_component)):
        groups: dict[str, list[dict]] = defaultdict(list)
        for d in yaml.safe_load_all(Path(path).read_text()):
            if not d:
                continue
            if d["kind"] == "CustomResourceDefinition":
                crds.append(d["metadata"]["name"])
                continue
            groups[classify(d)].append(redact(d))
        (out / part).mkdir(parents=True, exist_ok=True)
        chart = "log-platform-operators" if part == "operators" else "log-platform"
        for key in titles:
            docs = groups.get(key)
            if not docs:
                continue
            header = (f"# {titles[key]}\n"
                      f"# GENERATED by scripts/render-manifests.sh: chart {chart}, environment {a.env}"
                      f"{' + ' + ', '.join(overlays) if overlays else ''}.\n"
                      f"# Do not edit: change the chart or the environment and re-render. Secret data is redacted.\n")
            body = "\n".join("---\n" + yaml.safe_dump(d, sort_keys=False, width=200) for d in docs)
            (out / part / f"{key}.yaml").write_text(header + body)
            kinds = defaultdict(int)
            for d in docs:
                kinds[d["kind"]] += 1
            index.append((part, key, titles[key], ", ".join(f"{n} {k}" for k, n in sorted(kinds.items()))))

    lines = [f"# Rendered manifests: environment `{a.env}`", "",
             f"Generated by `scripts/render-manifests.sh {a.env}` from `environments/{a.env}/`"
             + (f" with overlays {', '.join(f'`{o}`' for o in overlays)}" if overlays else "") + ".",
             "Do not edit: change the charts or the environment and re-render. Install with the charts",
             "(`scripts/install.sh`), not with these files: Secret data here is redacted, and Secrets copied",
             "at install time (Percona users) are missing.", "",
             "| File | What | Objects |", "|---|---|---|"]
    for part, key, title, kinds in index:
        lines.append(f"| [`{part}/{key}.yaml`]({part}/{key}.yaml) | {title} | {kinds} |")
    if crds:
        lines += ["", "CRDs, installed by the operators chart (not copied here):", ""]
        lines += [f"- `{c}`" for c in sorted(set(crds))]
    lines += ["", "Also from the operators chart's `crds/` folder (Helm installs them first):",
              "Gateway API, kgateway, Keycloak, and Strimzi's (from its chart).", ""]
    (out / "README.md").write_text("\n".join(lines))
    print(f"{out}: {sum(1 for _ in out.rglob('*.yaml'))} files")


if __name__ == "__main__":
    main()

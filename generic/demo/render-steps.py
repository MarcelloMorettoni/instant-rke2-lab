#!/usr/bin/env python3
"""Render the demo chart into one manifest per step: generic/demo/steps/.

    generic/demo/render-steps.py          (re-run after changing the chart or its values)
    generic/demo/render-steps.py --check  (exit 1 if steps/ is out of date; validate.sh runs it)

The step files are exactly what `helm upgrade --install` would create, split
in install order, with a header that says what the step adds and how to know
it's ready (`# wait:` lines, which walkthrough.sh runs). Step 00 (CRDs) holds
Strimzi's, extracted from its chart; kgateway and the Gateway API CRDs are
already on the cluster. Each step carries its own CiliumNetworkPolicies.
"""
import re
import subprocess
import sys
import tarfile
from pathlib import Path

DEMO = Path(__file__).resolve().parent
CHART = DEMO / "chart"
OUT = DEMO / "steps"
NS = "observability"

CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition", "PriorityClass",
                  "StorageClass", "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration",
                  "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding", "GatewayClass",
                  "PersistentVolume", "CiliumClusterwideNetworkPolicy"}


def with_namespace(doc: str) -> str:
    """Stamp `namespace: observability` on a namespaced object that has none, so
    `kubectl apply -f` (without -n) puts everything where Helm would."""
    kind = re.search(r"(?m)^kind: (\w+)", doc)
    if not kind or kind.group(1) in CLUSTER_SCOPED:
        return doc
    lines = doc.split("\n")
    for i, line in enumerate(lines):
        if line == "metadata:":
            j = i + 1
            while j < len(lines) and (lines[j].startswith(" ") or not lines[j]):
                if lines[j].startswith("  namespace:"):
                    return doc
                j += 1
            lines.insert(i + 1, f"  namespace: {NS}")
            return "\n".join(lines)
    return doc


# (file, title, what it adds, which rendered sources belong to it, wait commands)
STEPS = [
    ("01-namespace", "The namespace",
     "Namespace observability, privileged Pod Security (the OTel agent reads /var/log/pods).",
     [r"/templates/01-namespace"], []),
    ("02-operators", "The Strimzi operator (runs Kafka; kgateway is already on the cluster)",
     "It watches this namespace for Kafka objects (step 4) and runs them.",
     [r"/charts/strimzi-kafka-operator/templates/", r"/templates/02-"],
     ["kubectl -n {ns} rollout status deploy/strimzi-cluster-operator --timeout=5m"]),
    ("03-object-storage", "Object storage (SeaweedFS, S3 API)",
     "Where Loki keeps every chunk and index file. A Job creates the buckets.",
     [r"/templates/03-object-storage"],
     ["kubectl -n {ns} wait --for=condition=complete job/seaweedfs-buckets --timeout=10m"]),
    ("04-kafka", "Kafka: 3 nodes, topic otel-logs, HTTP bridge",
     "The buffer between the OTel agents and gateways. Strimzi creates the pods.",
     [r"/templates/04-kafka"],
     ["kubectl -n {ns} wait kafka/logs --for=condition=Ready --timeout=15m",
      "kubectl -n {ns} wait kafkatopic/otel-logs --for=condition=Ready --timeout=5m",
      "kubectl -n {ns} wait kafkabridge/logs --for=condition=Ready --timeout=10m"]),
    ("05-loki", "Loki, distributed: distributors, 6 zone-aware ingesters, query path, index gateways, compactor, ruler, caches",
     "The log store. Zones are logical (zone-a/b/c): each stream lives on one ingester per zone.",
     [r"/charts/loki/", r"/templates/05-"],
     ["kubectl -n {ns} wait pod -l app.kubernetes.io/name=loki --for=condition=Ready --timeout=15m"]),
    ("06-otel", "OpenTelemetry: the agent on every node and the gateway",
     "The agents start reading the namespace's logs and write them to Kafka; the gateways consume them into Loki.",
     [r"/templates/06-otel"],
     ["kubectl -n {ns} rollout status ds/otel-agent --timeout=5m",
      "kubectl -n {ns} rollout status sts/otel-gateway --timeout=5m"]),
    ("07-read-gateway", "The read gateway (on the cluster's kgateway): one view + key per tenant; metrics store + tenant guard",
     "The only way to read Loki and the recorded metrics. The ruler writes to the metrics store from now on.",
     [r"/templates/07-read-gateway"],
     ["kubectl -n {ns} wait gateway/obs-gateway --for=condition=Programmed --timeout=5m",
      "kubectl -n {ns} rollout status deploy/obs-metrics-proxy --timeout=5m"]),
    ("08-grafana", "Grafana and grafana-sync: orgs, data sources, local users",
     "admin sees every tenant; tenant-a/b/c each only their own org.",
     [r"/charts/grafana/", r"/templates/08-grafana"],
     ["kubectl -n {ns} rollout status deploy/grafana --timeout=5m",
      "kubectl -n {ns} wait --for=condition=complete job/grafana-sync-now --timeout=10m"]),
    ("09-demonstrator", "The demonstrator: the web page that follows a log line",
     "kubectl -n observability port-forward svc/log-flow-demonstrator 8080:8080 → http://localhost:8080",
     [r"/templates/09-demonstrator"],
     ["kubectl -n {ns} rollout status deploy/log-flow-demonstrator --timeout=5m"]),
    ("10-tenants", "The tenants: tenant-a, tenant-b, tenant-c, each with an app that logs",
     "Their logs reach the platform with nothing configured in their namespaces.",
     [r"/templates/10-tenants"],
     ["kubectl -n tenant-a rollout status deploy/payments --timeout=5m",
      "kubectl -n tenant-b rollout status deploy/orders --timeout=5m",
      "kubectl -n tenant-c rollout status deploy/inventory --timeout=5m"]),
]


def main() -> int:
    check = "--check" in sys.argv[1:]
    written = {}
    rendered = subprocess.run(
        ["helm", "template", "log-flow-demo", str(CHART), "-n", NS, "--set", "namespace.create=true"],
        capture_output=True, text=True)
    if rendered.returncode:
        sys.stderr.write(rendered.stderr)
        return 1
    docs = re.split(r"(?m)^---\n", rendered.stdout)
    buckets = {s[0]: [] for s in STEPS}
    unmatched = []
    for doc in docs:
        m = re.search(r"(?m)^# Source: (.+)$", doc)
        if not m or not doc.strip().replace(m.group(0), "").strip():
            continue
        src = m.group(1)
        for name, _, _, patterns, _ in STEPS:
            if any(re.search(p, src) for p in patterns):
                buckets[name].append(with_namespace(doc.strip()) + "\n")
                break
        else:
            unmatched.append(src)
    if unmatched:
        sys.stderr.write("not assigned to a step: " + ", ".join(sorted(set(unmatched))) + "\n")
        return 1

    strimzi = next((CHART / "charts").glob("strimzi-kafka-operator-*.tgz"))
    with tarfile.open(strimzi) as tar:
        parts = [tar.extractfile(m).read().decode() for m in sorted(tar.getmembers(), key=lambda m: m.name)
                 if "/crds/" in m.name and m.name.endswith(".yaml")]
    written["00-crds/strimzi-1.2.0.yaml"] = ("# Strimzi 1.2.0 CRDs, extracted from its chart by render-steps.py.\n"
                                             + "\n---\n".join(p.strip() for p in parts) + "\n")

    index = ["# The demo, step by step", "",
             "Generated by `render-steps.py` from `../chart` (the same objects as `helm install`). "
             "Apply them in order, or run `../walkthrough.sh`.", "",
             "| Step | What | Objects |", "|---|---|---|",
             "| [`00-crds/`](00-crds/) | Strimzi's CRDs (`kubectl apply --server-side`); kgateway and Gateway API are already installed | 1 file |"]
    for name, title, what, _, waits in STEPS:
        body = buckets[name]
        if not body:
            sys.stderr.write(f"step {name} is empty\n")
            return 1
        header = [f"# Step {name[:2]}: {title}", f"# {what}", "#",
                  f"#   kubectl apply -f {name}.yaml"]
        header += [f"# wait: {w.format(ns=NS)}" for w in waits]
        header += ["# GENERATED by generic/demo/render-steps.py from generic/demo/chart. Do not edit.", ""]
        written[f"{name}.yaml"] = "\n".join(header) + "---\n" + "---\n".join(body)
        kinds = {}
        for d in body:
            k = re.search(r"(?m)^kind: (\w+)", d)
            if k:
                kinds[k.group(1)] = kinds.get(k.group(1), 0) + 1
        index.append(f"| [`{name}.yaml`]({name}.yaml) | {title} | "
                     + ", ".join(f"{n} {k}" for k, n in sorted(kinds.items())) + " |")
    written["README.md"] = "\n".join(index) + "\n"
    if check:
        stale = [f for f, text in written.items() if not (OUT / f).exists() or (OUT / f).read_text() != text]
        if stale:
            sys.stderr.write("steps/ is out of date (run generic/demo/render-steps.py): " + ", ".join(stale) + "\n")
            return 1
        print(f"steps/ up to date ({len(written)} files)")
        return 0
    OUT.mkdir(exist_ok=True)
    for old in OUT.glob("[0-9][0-9]-*.yaml"):
        old.unlink()
    crds = OUT / "00-crds"
    crds.mkdir(exist_ok=True)
    for f in crds.iterdir():
        f.unlink()
    for f, text in written.items():
        (OUT / f).write_text(text)
    print(f"{OUT.relative_to(DEMO.parent.parent)}: {len(STEPS)} step files + 00-crds/")
    return 0


if __name__ == "__main__":
    sys.exit(main())

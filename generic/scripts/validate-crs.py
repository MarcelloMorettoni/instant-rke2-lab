#!/usr/bin/env python3
"""Validate Kubernetes objects against the OpenAPI schemas in their CRDs.

    validate-crs.py --crds DIR_OR_FILE... --manifests DIR_OR_FILE...

Built-in kinds (Deployment, NetworkPolicy, ...) are only checked for
apiVersion/kind/metadata.name; custom resources (Gateway API, kgateway,
External Secrets, Azure managed Prometheus) are checked against the CRD's
openAPIV3Schema, so a misspelt or misplaced field fails here, not in the cluster.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator


def yaml_docs(paths: list[str]):
    for p in paths:
        path = Path(p)
        files = sorted(path.rglob("*.yaml")) + sorted(path.rglob("*.yml")) if path.is_dir() else [path]
        for f in files:
            for doc in yaml.safe_load_all(f.read_text()):
                if isinstance(doc, dict):
                    yield f, doc


COMBINATORS = {"oneOf", "anyOf", "allOf", "not"}


def strip_k8s_extensions(schema, in_combinator=False):
    """x-kubernetes-* keys mean nothing to jsonschema; int-or-string needs a type hint.

    Branches of oneOf/anyOf/allOf only constrain part of an object (e.g. "exactly
    one of endpointSelector / nodeSelector"), so they are never made strict.
    """
    if isinstance(schema, dict):
        out = {k: strip_k8s_extensions(v, k in COMBINATORS)
               for k, v in schema.items() if not k.startswith("x-kubernetes-")}
        if schema.get("x-kubernetes-int-or-string"):
            out.pop("type", None)
            out["anyOf"] = [{"type": "integer"}, {"type": "string"}]
        if schema.get("x-kubernetes-preserve-unknown-fields") and "properties" not in schema:
            out.pop("type", None)
        # The API server silently PRUNES unknown fields; a typo would vanish
        # without an error. Here an unknown field is an error.
        if "properties" in schema and "additionalProperties" not in schema and not in_combinator \
                and not schema.get("x-kubernetes-preserve-unknown-fields"):
            out["additionalProperties"] = False
        return out
    if isinstance(schema, list):
        return [strip_k8s_extensions(v, in_combinator) for v in schema]
    return schema


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--crds", nargs="+", required=True)
    ap.add_argument("--alias", nargs="*", default=[], metavar="FROM=TO",
                    help="also register CRDs of API group FROM under group TO "
                         "(e.g. monitoring.coreos.com=azmonitoring.coreos.com)")
    ap.add_argument("--manifests", nargs="+", required=True)
    args = ap.parse_args()

    schemas: dict[tuple[str, str], dict] = {}
    for _, doc in yaml_docs(args.crds):
        if doc.get("kind") != "CustomResourceDefinition":
            continue
        group = doc["spec"]["group"]
        kind = doc["spec"]["names"]["kind"]
        for v in doc["spec"]["versions"]:
            s = (v.get("schema") or {}).get("openAPIV3Schema")
            if s:
                schemas[(f"{group}/{v['name']}", kind)] = strip_k8s_extensions(s)
                for a in args.alias:
                    src, dst = a.split("=", 1)
                    if group == src:
                        schemas[(f"{dst}/{v['name']}", kind)] = schemas[(f"{group}/{v['name']}", kind)]

    failures = checked = 0
    for f, doc in yaml_docs(args.manifests):
        api, kind = doc.get("apiVersion"), doc.get("kind")
        name = (doc.get("metadata") or {}).get("name")
        if kind == "Kustomization" or ("groups" in doc and not kind):
            continue                      # kustomization.yaml, Prometheus rule files
        if not (api and kind and name):
            print(f"FAIL {f}: object without apiVersion/kind/metadata.name")
            failures += 1
            continue
        schema = schemas.get((api, kind))
        if schema is None:
            if "/" in api and not api.endswith(".k8s.io/v1") and "." in api.split("/")[0]:
                print(f"WARN {f}: no CRD schema loaded for {api} {kind} ({name})")
            continue
        checked += 1
        errors = sorted(Draft202012Validator(schema).iter_errors(doc), key=lambda e: e.path)
        for e in errors:
            loc = ".".join(str(p) for p in e.absolute_path) or "(root)"
            print(f"FAIL {f.name}: {kind}/{name} {loc}: {e.message[:300]}")
        failures += bool(errors)
    print(f"{checked} custom resources checked against CRD schemas, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

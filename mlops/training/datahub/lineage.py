"""Prints what a model version was built from, as DataHub knows it.

  datahub-py - <model-version> < mlops/training/datahub/lineage.py

Run `datahub-ingest` once before: it creates the access token this script reads.
"""
import sys

import requests

version = sys.argv[1]
token = open("/tmp/token").read()
QUERY = """query($urn: String!) { searchAcrossLineage(input: {urn: $urn, direction: UPSTREAM, query: "*", count: 30}) {
  searchResults { degree entity { urn type } } } }"""
urn = f"urn:li:mlModel:(urn:li:dataPlatform:mlflow,sensor-fault_{version},PROD)"
reply = requests.post(
    "http://datahub-datahub-gms:8080/api/graphql", json={"query": QUERY, "variables": {"urn": urn}},
    headers={"Authorization": f"Bearer {token}"}, timeout=60,
).json()
if reply.get("errors"):
    sys.exit(f"DataHub error: {reply['errors'][0]['message']}")
results = sorted(reply["data"]["searchAcrossLineage"]["searchResults"], key=lambda r: r["degree"])
print(f"sensor-fault version {version}: {len(results)} upstream entities")
for r in results:
    kind = {"DATA_PROCESS_INSTANCE": "training run", "DATASET": "dataset"}.get(r["entity"]["type"], r["entity"]["type"])
    print(f"  {r['degree']} step(s) back  {kind:<13} {r['entity']['urn']}")
if not results:
    print("  nothing: either the version is not ingested yet, or its run did not log a dataset")

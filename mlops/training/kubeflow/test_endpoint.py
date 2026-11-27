"""A few tests against one or more KServe endpoints, run from inside the cluster.

  kf-kit - my-model < test_endpoint.py
  kf-kit - my-model my-model-experiment < test_endpoint.py

Per endpoint:
  ready       the model server reports the model as loaded
  contract    N readings in -> N predictions out, each 0 or 1
  accuracy    200 fresh generated readings, share predicted right (must be >= 0.75)
  stable      the same request twice gives the same answer
  bad input   a reading with a missing value is refused, not answered
  latency     20 single-reading requests, median must be under 1 second
  version     the endpoint serves the newest version in the Model Registry

With two or more endpoints it also prints how often they agree (information, not a test).
Exit code 1 when a test fails.
"""
import statistics
import sys
import time

import requests
import tabular

MIN_ACCURACY, MAX_MEDIAN_SECONDS = 0.75, 1.0
names = sys.argv[1:] or ["my-model"]
namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
batch = tabular.gen_batch(7, 200)  # seed 7: not a batch any model was trained on
rows, labels = batch[tabular.FEATURES].values.tolist(), batch.fault.tolist()
failed, answers = 0, {}


def check(name: str, test: str, ok: bool, detail: str) -> None:
    global failed
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  {name:24s} {test:10s} {detail}", flush=True)


def served_version(name: str) -> str:
    from kubernetes import client, config

    config.load_incluster_config()
    isvc = client.CustomObjectsApi().get_namespaced_custom_object("serving.kserve.io", "v1beta1", namespace, "inferenceservices", name)
    return isvc["metadata"].get("labels", {}).get("model-version", "?")


def registry_version(name: str) -> str:
    from model_registry import ModelRegistry

    registry = ModelRegistry(server_address="http://model-registry-service.kubeflow.svc.cluster.local", port=8080, author="test", is_secure=False)
    return f"v{len(list(registry.get_model_versions(name)))}"


for name in names:
    base = f"http://{name}-predictor.{namespace}.svc.cluster.local/v1/models/{name}"
    try:
        r = requests.get(base, timeout=180)  # the first call may wake a scaled-to-zero endpoint
        check(name, "ready", r.status_code == 200 and r.json().get("ready") in (True, "True"), f"HTTP {r.status_code} {r.text.strip()[:60]}")

        r = requests.post(f"{base}:predict", json={"instances": rows}, timeout=180)
        predictions = r.json().get("predictions", []) if r.status_code == 200 else []
        answers[name] = predictions
        check(name, "contract", len(predictions) == len(rows) and set(predictions) <= {0, 1}, f"HTTP {r.status_code}, {len(predictions)} predictions for {len(rows)} readings")

        accuracy = sum(p == y for p, y in zip(predictions, labels)) / len(labels) if predictions else 0.0
        check(name, "accuracy", accuracy >= MIN_ACCURACY, f"{accuracy:.3f} on 200 fresh readings (minimum {MIN_ACCURACY})")

        again = requests.post(f"{base}:predict", json={"instances": rows}, timeout=60).json().get("predictions")
        check(name, "stable", again == predictions, "same request, same answer" if again == predictions else "answers differ between two calls")

        r = requests.post(f"{base}:predict", json={"instances": [rows[0][:-1]]}, timeout=60)
        check(name, "bad input", r.status_code >= 400, f"3 values instead of 4 -> HTTP {r.status_code}")

        times = []
        for row in rows[:20]:
            t0 = time.perf_counter()
            requests.post(f"{base}:predict", json={"instances": [row]}, timeout=60).raise_for_status()
            times.append(time.perf_counter() - t0)
        median = statistics.median(times)
        check(name, "latency", median < MAX_MEDIAN_SECONDS, f"median {median * 1000:.0f} ms, slowest {max(times) * 1000:.0f} ms over 20 requests")

        served, newest = served_version(name), registry_version(name)
        check(name, "version", served == newest, f"serving {served}, newest in the registry {newest}")
    except Exception as e:  # an endpoint that does not answer fails its remaining tests at once
        check(name, "reachable", False, f"{type(e).__name__}: {str(e)[:100]}")

for i, a in enumerate(names):
    for b in names[i + 1:]:
        if answers.get(a) and answers.get(b):
            same = sum(x == y for x, y in zip(answers[a], answers[b]))
            print(f"  INFO  {a} and {b} give the same answer on {same} of {len(rows)} readings")

print(f"\n{'ALL TESTS PASSED' if not failed else f'{failed} TEST(S) FAILED'}")
sys.exit(1 if failed else 0)

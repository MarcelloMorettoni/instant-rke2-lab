"""Sends five generated sensor readings to a KServe endpoint and compares with the true labels.

  kf-kit - < predict.py               the endpoint sensor-fault
  kf-kit - my-model < predict.py      another endpoint
"""
import sys

import requests
import tabular

name = sys.argv[1] if len(sys.argv) > 1 else "sensor-fault"
namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
rows = tabular.gen_batch(99, 5)
response = requests.post(
    f"http://{name}-predictor.{namespace}.svc.cluster.local/v1/models/{name}:predict",
    json={"instances": rows[tabular.FEATURES].values.tolist()}, timeout=180,
)
print("status   ", response.status_code)
print("predicted", response.json()["predictions"])
print("expected ", rows.fault.tolist())

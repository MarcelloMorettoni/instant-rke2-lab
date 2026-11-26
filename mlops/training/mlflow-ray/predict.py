"""Sends five generated sensor readings to a Ray Serve endpoint and compares with the true labels.

  mr-kit - < predict.py               the endpoint sensor-fault
  mr-kit - my-model < predict.py      another endpoint
"""
import sys

import requests
import tabular

name = sys.argv[1] if len(sys.argv) > 1 else "sensor-fault"
rows = tabular.gen_batch(99, 5)
response = requests.post(f"http://{name}-serve-svc:8000/", json={"instances": rows[tabular.FEATURES].values.tolist()}, timeout=180)
print("status   ", response.status_code)
print("response ", response.text[:200])
print("expected ", rows.fault.tolist())

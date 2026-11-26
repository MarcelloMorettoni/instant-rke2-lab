"""Sends five generated sensor readings to the Ray Serve endpoint and compares with the true labels."""
import requests
import tabular

rows = tabular.gen_batch(99, 5)
response = requests.post("http://sensor-fault-serve-svc:8000/", json={"instances": rows[tabular.FEATURES].values.tolist()}, timeout=180)
print("status   ", response.status_code)
print("response ", response.text[:200])
print("expected ", rows.fault.tolist())

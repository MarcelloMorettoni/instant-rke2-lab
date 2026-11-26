"""Sends five generated sensor readings to the KServe endpoint and compares with the true labels."""
import requests
import tabular

namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
rows = tabular.gen_batch(99, 5)
response = requests.post(
    f"http://sensor-fault-predictor.{namespace}.svc.cluster.local/v1/models/sensor-fault:predict",
    json={"instances": rows[tabular.FEATURES].values.tolist()}, timeout=180,
)
print("status   ", response.status_code)
print("predicted", response.json()["predictions"])
print("expected ", rows.fault.tolist())

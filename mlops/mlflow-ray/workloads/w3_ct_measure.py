"""Measures the continuous-training loop on MLflow + Ray: new data in the bucket
-> new champion version in MLflow -> served by Ray Serve. Run in the kit pod
while the CronWorkflow is enabled."""
import datetime
import os
import sys
import time

import mlflow
import requests
import dataset
import tabular

seed, ds = int(sys.argv[1]), dataset.Dataset()
now = lambda: datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S")
client = mlflow.MlflowClient()

t0, registered = time.time(), None
target = ds.add_batch(f"batch-{seed:03d}.csv", tabular.to_csv_bytes(tabular.gen_batch(seed, drift=1.5)))
print(now(), f"uploaded batch-{seed:03d}.csv, dataset version {ds.uri(target)}", flush=True)
while time.time() - t0 < 1500:
    if registered is None:
        for mv in client.search_model_versions("name='sensor-fault'"):
            if mv.tags.get("data_fingerprint") == target:
                registered = mv.version
                print(now(), f"model version {mv.version} registered {time.time() - t0:.0f}s after the data arrived: {mv.tags}", flush=True)
    else:
        try:
            r = requests.post("http://sensor-fault-serve-svc:8000/", json={"instances": [[0.1, -0.2, 0.3, 0.4]]}, timeout=10).json()
            if str(r["model_version"]) == str(registered):
                print(now(), f"version {registered} served {time.time() - t0:.0f}s after the data arrived", flush=True)
                break
        except Exception:
            pass
    time.sleep(5)
else:
    print(now(), "TIMEOUT")
    sys.exit(1)

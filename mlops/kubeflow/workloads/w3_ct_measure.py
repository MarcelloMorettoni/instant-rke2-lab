"""Measures the continuous-training loop: new data in the store -> new model version.

Run in the kit pod while a recurring W3 run is scheduled. Uploads one drifted
batch, then polls Model Registry until a version trained on the new dataset
version appears.

  w3_ct_measure.py <prefix> <seed> [bucket-or-lakefs-repo]
"""
import datetime
import sys
import time

import requests
import dataset
import tabular

prefix, seed = sys.argv[1], int(sys.argv[2])
REG = "http://model-registry-service.kubeflow.svc.cluster.local:8080/api/model_registry/v1alpha3"
now = lambda: datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S")


def versions():
    out = {}
    for v in requests.get(f"{REG}/registered_models/1/versions", timeout=30).json().get("items", []):
        props = {k: x.get("string_value", x.get("double_value")) for k, x in v["customProperties"].items()}
        out[props.get("data_fingerprint")] = (v["name"], props)
    return out


ds = dataset.Dataset(sys.argv[3] if len(sys.argv) > 3 else "mlpipeline", prefix)
t0 = time.time()
target = ds.add_batch(f"batch-{seed:03d}.csv", tabular.to_csv_bytes(tabular.gen_batch(seed, drift=1.5)))
print(now(), f"uploaded batch-{seed:03d}.csv, dataset version {ds.uri(target)}", flush=True)
while time.time() - t0 < 1500:
    found = versions().get(target)
    if found:
        print(now(), f"model {found[0]} registered {time.time() - t0:.0f}s after the data arrived: {found[1]}", flush=True)
        break
    time.sleep(5)
else:
    print(now(), "TIMEOUT: no version for the new fingerprint")
    sys.exit(1)

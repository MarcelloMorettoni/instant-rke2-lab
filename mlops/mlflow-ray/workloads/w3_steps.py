"""W3 on MLflow + Ray: the light pipeline steps (run as plain containers by Argo).

  python w3_steps.py detect    -> writes the dataset version, or "" if already trained
  python w3_steps.py validate  -> data quality gate; exits non-zero on bad data
"""
import os
import sys

import dataset
import tabular

ds = dataset.Dataset()

cmd = sys.argv[1]
if cmd == "detect":
    current = ds.version()
    done = ds.is_trained("sensor-fault", current)
    print(f"dataset {ds.uri(current)} already trained={done}", file=sys.stderr)
    with open("/tmp/fingerprint", "w") as f:
        f.write("" if done else current)
elif cmd == "validate":
    df, keys = ds.load(os.environ.get("DATA_VERSION") or ds.version())
    print(tabular.validate(df), "batches:", keys)

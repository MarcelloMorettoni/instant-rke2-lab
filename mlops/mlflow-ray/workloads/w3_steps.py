"""W3 on MLflow + Ray: the light pipeline steps (run as plain containers by Argo).

  python w3_steps.py detect    -> prints the dataset fingerprint, or "" if already trained
  python w3_steps.py validate  -> data quality gate; exits non-zero on bad data
"""
import os
import sys

import pandas as pd

import s3
import tabular

BUCKET, PREFIX = os.environ["S3_BUCKET"], os.environ.get("DATA_PREFIX", "datasets/w3")

cmd = sys.argv[1]
if cmd == "detect":
    current = s3.fingerprint(BUCKET, PREFIX)
    trained = s3.get_text(BUCKET, f"{PREFIX}/_trained_fingerprint")
    print(f"dataset fingerprint={current} last trained={trained or '(never)'}", file=sys.stderr)
    with open("/tmp/fingerprint", "w") as f:
        f.write("" if current == trained else current)
elif cmd == "validate":
    keys = [o["Key"] for o in s3.list_keys(BUCKET, PREFIX)]
    df = pd.concat([tabular.from_csv_bytes(s3.get_bytes(BUCKET, k)) for k in keys], ignore_index=True)
    print(tabular.validate(df), "batches:", keys)

"""The light steps of the pipeline, run as plain containers by Argo Workflows.

  python steps.py detect    -> writes the data version to train on, or "" when there is nothing to do
  python steps.py validate  -> data quality gate; exits non-zero on bad data
"""
import os
import sys

import dataset
import tabular

ds = dataset.Dataset(os.environ["DATA_REPO"])

if sys.argv[1] == "detect":
    # A run that picks a commit up marks it with a tag tried-<model>-<commit>, so the
    # schedule tries every commit once, also when that run fails. retrain=yes
    # trains anyway: CI sets it, because then the code changed.
    import lakefs

    model, retrain = os.environ["MODEL_NAME"], os.environ.get("RETRAIN", "no")
    current = ds.version()
    tried = current in lakefs.tags(ds.repo, f"tried-{model}-").values()
    print(f"data {ds.uri(current)} already tried={tried} retrain={retrain}", file=sys.stderr)
    go = retrain == "yes" or not tried
    if go:
        lakefs.tag(ds.repo, f"tried-{model}-{current[:12]}", current)
    with open("/tmp/version", "w") as f:
        f.write(current if go else "")
elif sys.argv[1] == "validate":
    df, keys = ds.load(os.environ["DATA_VERSION"])
    print(tabular.validate(df), "files:", keys)

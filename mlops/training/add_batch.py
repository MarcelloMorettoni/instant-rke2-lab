"""Adds one batch of sensor readings to the project's dataset and commits it.

  kf-kit - <number> < mlops/training/add_batch.py      (same with mr-kit)

The number seeds the generator and names the file (batch-<number>.csv). Run it in
a project's workstation pod: the repository comes from the project's settings.
"""
import sys

import dataset
import tabular

seed = int(sys.argv[1])
ds = dataset.Dataset()
before = ds.version()
after = ds.add_batch(f"batch-{seed:03d}.csv", tabular.to_csv_bytes(tabular.gen_batch(seed, drift=1.5)), f"Training: batch {seed}")
print("repository    ", ds.repo)
print("version before", before)
print("version after ", after)

"""For every model version the pipeline trained, reads back the dataset exactly as it was.

  kf-kit - < mlops/training/dataset_of_model.py        (same with mr-kit)

The pipeline tags the lakeFS commit it trained on as trained-<model>-<version>.
"""
import dataset
import lakefs

ds = dataset.Dataset()
for tag, commit in sorted(lakefs.tags(ds.repo, "trained-").items()):
    frame, keys = ds.load(commit)
    print(f"{tag:<28} commit {commit[:12]}  {len(keys)} files  {len(frame)} rows")

"""Where the W3 training data lives, and how a dataset state is identified.

  DATA_STORE=s3 (default)  plain bucket prefix. The version is a fingerprint of
                           the object list; old states cannot be read back.
  DATA_STORE=lakefs        lakeFS repository. The version is a commit id; every
                           trained state stays readable, and a tag on the commit
                           records which model version was trained on it.

The pipelines only use this class, so switching store is configuration.
"""
from __future__ import annotations

import os

import s3


class Dataset:
    def __init__(self, location: str | None = None, prefix: str | None = None):
        self.store = os.environ.get("DATA_STORE", "s3")
        self.prefix = (prefix or os.environ.get("DATA_PREFIX", "datasets/w3")).strip("/")
        if self.store == "lakefs":
            self.repo = location or os.environ["LAKEFS_REPO"]
            self.branch = os.environ.get("LAKEFS_BRANCH", "main")
        else:
            self.bucket = location or os.environ["S3_BUCKET"]

    def version(self) -> str:
        """Id of the current dataset state."""
        if self.store == "lakefs":
            import lakefs

            return lakefs.head(self.repo, self.branch)
        return s3.fingerprint(self.bucket, self.prefix)

    def is_trained(self, model: str, version: str) -> bool:
        if self.store == "lakefs":
            import lakefs

            return version in lakefs.tags(self.repo, f"trained-{model}-").values()
        return s3.get_text(self.bucket, f"{self.prefix}/_trained_fingerprint") == version

    def mark_trained(self, model: str, version: str, model_version: str) -> None:
        if self.store == "lakefs":
            import lakefs

            lakefs.tag(self.repo, f"trained-{model}-{model_version}", version)
        else:
            s3.put_bytes(self.bucket, f"{self.prefix}/_trained_fingerprint", version.encode())

    def load(self, version: str):
        """(DataFrame, object keys). On lakeFS this reads exactly `version`."""
        import pandas as pd
        import tabular

        if self.store == "lakefs":
            import lakefs

            keys = lakefs.list_keys(self.repo, version, self.prefix)
            frames = [tabular.from_csv_bytes(lakefs.get_bytes(self.repo, k)) for k in keys]
        else:
            keys = [o["Key"] for o in s3.list_keys(self.bucket, self.prefix)]
            frames = [tabular.from_csv_bytes(s3.get_bytes(self.bucket, k)) for k in keys]
        return pd.concat(frames, ignore_index=True), keys

    def add_batch(self, name: str, data: bytes, message: str = "") -> str:
        """Adds one file and returns the new dataset version."""
        if self.store == "lakefs":
            import lakefs

            lakefs.put_bytes(self.repo, self.branch, f"{self.prefix}/{name}", data)
            return lakefs.commit(self.repo, self.branch, message or f"add {name}")
        s3.put_bytes(self.bucket, f"{self.prefix}/{name}", data)
        return self.version()

    def uri(self, version: str) -> str:
        if self.store == "lakefs":
            return f"lakefs://{self.repo}/{version}/{self.prefix}/"
        return f"s3://{self.bucket}/{self.prefix}/#{version}"

    def catalog(self, version: str) -> tuple[str, str]:
        """(name, source URI) under which a data catalog knows this dataset.

        For lakeFS the name is the branch path, which is what DataHub's S3 source
        produces when it scans the lakeFS gateway; the source pins the commit.
        """
        if self.store == "lakefs":
            return f"{self.repo}/{self.branch}/{self.prefix}", f"s3://{self.repo}/{version}/{self.prefix}/"
        return f"{self.bucket}/{self.prefix}", f"s3://{self.bucket}/{self.prefix}/"

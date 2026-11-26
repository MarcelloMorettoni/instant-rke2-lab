"""lakeFS helpers: objects through its S3 gateway, versioning through its REST API.

Configuration from the environment:
  LAKEFS_ENDPOINT, LAKEFS_ACCESS_KEY_ID, LAKEFS_SECRET_ACCESS_KEY

Through the gateway a repository is the bucket and the key starts with a ref:
  s3://<repo>/<branch | tag | commit id>/<path>
"""
from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request

import boto3
from botocore.client import Config


def _endpoint() -> str:
    return os.environ["LAKEFS_ENDPOINT"].rstrip("/")


def _api(method: str, path: str, body: dict | None = None) -> dict:
    cred = f'{os.environ["LAKEFS_ACCESS_KEY_ID"]}:{os.environ["LAKEFS_SECRET_ACCESS_KEY"]}'
    req = urllib.request.Request(
        f"{_endpoint()}/api/v1{path}",
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Basic " + base64.b64encode(cred.encode()).decode(), "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else {}


def _s3():
    return boto3.client(
        "s3",
        endpoint_url=_endpoint(),
        aws_access_key_id=os.environ["LAKEFS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["LAKEFS_SECRET_ACCESS_KEY"],
        region_name="us-east-1",
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def head(repo: str, branch: str) -> str:
    """Commit id the branch points at."""
    return _api("GET", f"/repositories/{repo}/branches/{branch}")["commit_id"]


def commit(repo: str, branch: str, message: str, metadata: dict | None = None) -> str:
    return _api("POST", f"/repositories/{repo}/branches/{branch}/commits", {"message": message, "metadata": metadata or {}})["id"]


def tags(repo: str, prefix: str = "") -> dict[str, str]:
    """{tag name: commit id}"""
    out = _api("GET", f"/repositories/{repo}/tags?prefix={prefix}&amount=1000")
    return {t["id"]: t["commit_id"] for t in out.get("results", [])}


def tag(repo: str, name: str, ref: str) -> None:
    try:
        _api("POST", f"/repositories/{repo}/tags", {"id": name, "ref": ref})
    except urllib.error.HTTPError as e:
        if e.code != 409:  # tags are immutable; the same tag twice is fine
            raise


def list_keys(repo: str, ref: str, prefix: str) -> list[str]:
    out = []
    for page in _s3().get_paginator("list_objects_v2").paginate(Bucket=repo, Prefix=f"{ref}/{prefix.strip('/')}/"):
        out += [o["Key"] for o in page.get("Contents", []) if o["Key"].endswith(".csv")]
    return sorted(out)


def get_bytes(repo: str, key: str) -> bytes:
    return _s3().get_object(Bucket=repo, Key=key)["Body"].read()


def put_bytes(repo: str, branch: str, path: str, data: bytes) -> None:
    _s3().put_object(Bucket=repo, Key=f"{branch}/{path}", Body=data)

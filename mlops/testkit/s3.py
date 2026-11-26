"""Object-store helpers shared by every candidate.

Configuration comes from the environment so the same code runs against the
store each candidate ships with:
  S3_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
"""
from __future__ import annotations

import hashlib
import os

import boto3
from botocore.client import Config


def client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT"],
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def ensure_bucket(bucket: str) -> None:
    s3 = client()
    try:
        s3.head_bucket(Bucket=bucket)
    except Exception:
        s3.create_bucket(Bucket=bucket)


def list_keys(bucket: str, prefix: str) -> list[dict]:
    s3, out = client(), []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        out += [o for o in page.get("Contents", []) if o["Key"].endswith(".csv")]
    return sorted(out, key=lambda o: o["Key"])


def fingerprint(bucket: str, prefix: str) -> str:
    """Stable id of a dataset state: changes when a batch is added or replaced."""
    h = hashlib.sha256()
    for o in list_keys(bucket, prefix):
        h.update(f'{o["Key"]}:{o["ETag"]}:{o["Size"]};'.encode())
    return h.hexdigest()[:16]


def get_bytes(bucket: str, key: str) -> bytes:
    return client().get_object(Bucket=bucket, Key=key)["Body"].read()


def put_bytes(bucket: str, key: str, data: bytes) -> None:
    client().put_object(Bucket=bucket, Key=key, Body=data)


def get_text(bucket: str, key: str, default: str = "") -> str:
    try:
        return get_bytes(bucket, key).decode()
    except Exception:
        return default

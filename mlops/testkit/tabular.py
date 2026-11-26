"""Shared tabular workload (W3): the same data, checks and model for every candidate.

A small synthetic "sensor fault" classification problem. Batches are
deterministic per seed, and `drift` shifts the feature distribution so a later
batch really does change the model.
"""
from __future__ import annotations

import io

import numpy as np
import pandas as pd

FEATURES = ["temperature", "vibration", "pressure", "current"]
TARGET = "fault"
SCHEMA = {**{f: "float64" for f in FEATURES}, TARGET: "int64"}
MIN_ROWS = 200
ACCURACY_GATE = 0.80


def gen_batch(seed: int, rows: int = 500, drift: float = 0.0) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    x = rng.normal(loc=drift, scale=1.0, size=(rows, len(FEATURES)))
    logit = 1.6 * x[:, 0] - 1.1 * x[:, 1] + 0.7 * x[:, 2] * x[:, 3] - 0.5 * drift
    y = (logit + rng.normal(scale=0.6, size=rows) > 0).astype("int64")
    df = pd.DataFrame(x, columns=FEATURES)
    df[TARGET] = y
    return df


def to_csv_bytes(df: pd.DataFrame) -> bytes:
    return df.to_csv(index=False).encode()


def from_csv_bytes(raw: bytes) -> pd.DataFrame:
    return pd.read_csv(io.BytesIO(raw))


def validate(df: pd.DataFrame) -> dict:
    """Data quality gate. Raises ValueError so the calling step fails."""
    problems = []
    missing = [c for c in SCHEMA if c not in df.columns]
    if missing:
        problems.append(f"missing columns: {missing}")
    else:
        for col, dtype in SCHEMA.items():
            if str(df[col].dtype) != dtype:
                problems.append(f"{col}: dtype {df[col].dtype}, expected {dtype}")
        if df[list(SCHEMA)].isna().any().any():
            problems.append("null values present")
        if not set(df[TARGET].unique()) <= {0, 1}:
            problems.append("label outside {0,1}")
        positive = float(df[TARGET].mean())
        if not 0.1 <= positive <= 0.9:
            problems.append(f"class balance {positive:.2f} outside [0.1, 0.9]")
    if len(df) < MIN_ROWS:
        problems.append(f"only {len(df)} rows, need {MIN_ROWS}")
    if problems:
        raise ValueError("data validation failed: " + "; ".join(problems))
    return {"rows": int(len(df)), "positive_rate": float(df[TARGET].mean())}


def split(df: pd.DataFrame, seed: int = 0):
    from sklearn.model_selection import train_test_split

    return train_test_split(df, test_size=0.25, random_state=seed, stratify=df[TARGET])


def train(train_df: pd.DataFrame, n_estimators: int = 100, max_depth: int = 3, seed: int = 0):
    from sklearn.ensemble import GradientBoostingClassifier

    model = GradientBoostingClassifier(n_estimators=n_estimators, max_depth=max_depth, random_state=seed)
    model.fit(train_df[FEATURES].to_numpy(), train_df[TARGET].to_numpy())
    return model


def evaluate(model, test_df: pd.DataFrame) -> dict:
    from sklearn.metrics import accuracy_score, f1_score, roc_auc_score

    x, y = test_df[FEATURES].to_numpy(), test_df[TARGET].to_numpy()
    pred = model.predict(x)
    return {
        "accuracy": float(accuracy_score(y, pred)),
        "f1": float(f1_score(y, pred)),
        "roc_auc": float(roc_auc_score(y, model.predict_proba(x)[:, 1])),
    }

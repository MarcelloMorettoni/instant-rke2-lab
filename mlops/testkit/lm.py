"""Shared language-model workload (W2): fine-tune a small open LM on CPU.

The model, corpus and hyperparameters are identical for every candidate; only
the distribution layer differs (torchrun/DDP under Kubeflow Trainer, Ray Train
under Ray). The caller passes `prepare_model` / `prepare_loader` / `report`
hooks for its framework.
"""
from __future__ import annotations

import math
import os
import time
import urllib.request

MODEL_NAME = os.environ.get("LM_MODEL", "HuggingFaceTB/SmolLM2-135M")
CORPUS_URL = "https://raw.githubusercontent.com/karpathy/char-rnn/master/data/tinyshakespeare/input.txt"
DEFAULTS = {"steps": 30, "batch_size": 4, "block_size": 96, "lr": 5e-5, "corpus_bytes": 120_000, "seed": 0}


def load_corpus(n_bytes: int) -> str:
    with urllib.request.urlopen(CORPUS_URL, timeout=60) as r:
        return r.read(n_bytes).decode("utf-8", errors="ignore")


def build_dataset(tokenizer, text: str, block_size: int):
    import torch

    ids = tokenizer(text, return_tensors="pt").input_ids[0]
    n = (len(ids) // block_size) * block_size
    return torch.utils.data.TensorDataset(ids[:n].view(-1, block_size))


def finetune(config: dict | None = None, prepare_model=None, prepare_loader=None, report=None, sampler_fn=None):
    """Runs the training loop and returns (model, tokenizer, summary).

    summary = {"first_loss", "final_loss", "perplexity", "steps", "seconds"}
    """
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    cfg = {**DEFAULTS, **(config or {})}
    torch.manual_seed(cfg["seed"])

    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    model = AutoModelForCausalLM.from_pretrained(MODEL_NAME)
    dataset = build_dataset(tokenizer, load_corpus(cfg["corpus_bytes"]), cfg["block_size"])
    sampler = sampler_fn(dataset) if sampler_fn else None
    loader = torch.utils.data.DataLoader(
        dataset, batch_size=cfg["batch_size"], shuffle=sampler is None, sampler=sampler, drop_last=True
    )
    if prepare_loader:
        loader = prepare_loader(loader)
    if prepare_model:
        model = prepare_model(model)

    optim = torch.optim.AdamW(model.parameters(), lr=cfg["lr"])
    model.train()
    start, step, first, last = time.time(), 0, None, None
    while step < cfg["steps"]:
        for (batch,) in loader:
            loss = model(input_ids=batch, labels=batch).loss
            loss.backward()
            optim.step()
            optim.zero_grad()
            step += 1
            last = float(loss.detach())
            first = last if first is None else first
            if report:
                report({"loss": last, "step": step})
            if step >= cfg["steps"]:
                break
    summary = {
        "first_loss": first,
        "final_loss": last,
        "perplexity": math.exp(min(last, 20)),
        "steps": step,
        "seconds": round(time.time() - start, 1),
    }
    return model, tokenizer, summary

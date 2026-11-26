"""W2 on Kubeflow: multi-node fine-tuning with Kubeflow Trainer (torchrun + DDP).

Started by `torchrun` on every node of a TrainJob. Rank 0 tracks the run in
MLflow (Kubeflow has no experiment tracker of its own), uploads the model to the
profile's object-store prefix and registers it in Kubeflow Model Registry.
"""
import os
import socket

import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel
from torch.utils.data.distributed import DistributedSampler

import lm

dist.init_process_group(backend="gloo")  # CPU-only cluster
rank, world = dist.get_rank(), dist.get_world_size()
torch.set_num_threads(int(os.environ.get("OMP_NUM_THREADS", "2")))
print(f"[rank {rank}/{world}] host={socket.gethostname()} node={os.environ.get('NODE_NAME')}", flush=True)

tracking = rank == 0 and os.environ.get("MLFLOW_TRACKING_URI")
if tracking:
    import mlflow

    mlflow.set_experiment(os.environ.get("MLFLOW_EXPERIMENT", "kubeflow-w2-lm-finetune"))
    run = mlflow.start_run(run_name=os.environ.get("TRAINJOB_NAME", "w2"))
    mlflow.log_params({**lm.DEFAULTS, "model": lm.MODEL_NAME, "world_size": world, "backend": "kubeflow-trainer/torchrun-ddp"})


def report(m):
    if rank == 0 and m["step"] % 5 == 0:
        print(f"step {m['step']} loss {m['loss']:.4f}", flush=True)
    if tracking:
        mlflow.log_metric("loss", m["loss"], step=m["step"])


model, tokenizer, summary = lm.finetune(
    prepare_model=DistributedDataParallel,
    sampler_fn=lambda ds: DistributedSampler(ds, shuffle=True, seed=0),
    report=report,
)
print(f"[rank {rank}] summary {summary}", flush=True)

if rank == 0:
    import s3

    namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
    out, job = "/tmp/model", os.environ.get("TRAINJOB_NAME", "w2")
    model.module.save_pretrained(out)
    tokenizer.save_pretrained(out)
    prefix = f"private/{namespace}/models/w2/{job}"
    for name in os.listdir(out):
        s3.client().upload_file(os.path.join(out, name), "mlpipeline", f"{prefix}/{name}")
    uri = f"s3://mlpipeline/{prefix}"
    print("model uploaded to", uri, flush=True)

    from model_registry import ModelRegistry

    registry = ModelRegistry(
        server_address="http://model-registry-service.kubeflow.svc.cluster.local", port=8080, author="w2-trainjob", is_secure=False
    )
    try:
        n = len(list(registry.get_model_versions("smollm2-135m-shakespeare")))
    except Exception:
        n = 0
    meta = {"final_loss": summary["final_loss"], "world_size": world, "trainjob": job}
    if tracking:
        meta["mlflow_run_id"] = run.info.run_id
    registry.register_model(
        "smollm2-135m-shakespeare", uri, version=f"v{n + 1}", model_format_name="transformers",
        model_format_version="4", description="W2 multi-node fine-tune", metadata=meta,
    )
    print(f"registered smollm2-135m-shakespeare v{n + 1}", flush=True)
    if tracking:
        mlflow.log_metrics({k: v for k, v in summary.items() if k != "steps"})
        mlflow.set_tags({"model_registry_version": f"v{n + 1}", "model_uri": uri})
        mlflow.end_run()

dist.destroy_process_group()

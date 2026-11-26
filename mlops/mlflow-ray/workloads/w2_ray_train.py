"""W2 on MLflow + Ray: multi-node fine-tuning with Ray Train, tracked and
registered in MLflow. Same model, corpus and hyperparameters as the Kubeflow
variant (testkit/lm.py); Ray Train replaces torchrun/DDP wiring.
"""
import os
import socket

import ray
from ray.train import RunConfig, ScalingConfig
from ray.train.torch import TorchTrainer

MODEL_NAME = "smollm2-135m-shakespeare"


def train_loop(config):
    import mlflow
    import ray.train
    import ray.train.torch

    import lm

    ctx = ray.train.get_context()
    rank, world = ctx.get_world_rank(), ctx.get_world_size()
    print(f"[rank {rank}/{world}] host={socket.gethostname()} node={os.environ.get('NODE_NAME')}", flush=True)

    run = None
    if rank == 0:
        mlflow.set_experiment("w2-lm-finetune")
        run = mlflow.start_run(run_name=config["job_name"])
        mlflow.log_params({**lm.DEFAULTS, "model": lm.MODEL_NAME, "world_size": world, "backend": "ray-train"})

    def report(m):
        if rank == 0:
            mlflow.log_metric("loss", m["loss"], step=m["step"])
            if m["step"] % 5 == 0:
                print(f"step {m['step']} loss {m['loss']:.4f}", flush=True)

    model, tokenizer, summary = lm.finetune(
        prepare_model=ray.train.torch.prepare_model,
        prepare_loader=ray.train.torch.prepare_data_loader,
        report=report,
    )
    print(f"[rank {rank}] summary {summary}", flush=True)

    if rank == 0:
        import transformers

        plain = model.module if hasattr(model, "module") else model
        mlflow.log_metrics({k: v for k, v in summary.items() if k != "steps"})
        info = mlflow.transformers.log_model(
            transformers.pipeline("text-generation", model=plain, tokenizer=tokenizer),
            name="model",
            registered_model_name=MODEL_NAME,
            # Without this MLflow infers requirements and fails importing torchvision.
            pip_requirements=["torch==2.7.1", "transformers==4.53.2"],
        )
        print(f"registered {MODEL_NAME} version {info.registered_model_version} run {run.info.run_id}", flush=True)
        mlflow.end_run()
    ray.train.report(summary)


if __name__ == "__main__":
    ray.init()
    trainer = TorchTrainer(
        train_loop,
        train_loop_config={"job_name": os.environ.get("JOB_NAME", "w2")},
        scaling_config=ScalingConfig(num_workers=2, use_gpu=False, resources_per_worker={"CPU": 2}),
        run_config=RunConfig(name="w2-lm-finetune", storage_path="/tmp/ray_results"),
    )
    result = trainer.fit()
    print("result metrics:", result.metrics)

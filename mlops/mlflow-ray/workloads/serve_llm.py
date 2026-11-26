"""W4 on MLflow + Ray: the W2 fine-tuned language model behind Ray Serve with an
OpenAI-style completions API, autoscaling from zero replicas.

Ray's own LLM serving (`ray.serve.llm`) is built on vLLM and needs a GPU, so on
this CPU-only lab the deployment below wraps a transformers pipeline by hand.
"""
import os
import time
import uuid

from fastapi import FastAPI
from pydantic import BaseModel
from ray import serve

MODEL_URI = os.environ.get("LLM_MODEL_URI", "models:/smollm2-135m-shakespeare/1")
api = FastAPI()


class CompletionRequest(BaseModel):
    model: str = "smollm"
    prompt: str
    max_tokens: int = 24
    temperature: float = 0.0


@serve.deployment(
    ray_actor_options={"num_cpus": 2},
    autoscaling_config={
        "min_replicas": 0,
        "max_replicas": 3,
        "target_ongoing_requests": 1,
        "upscale_delay_s": 5,
        "downscale_delay_s": 60,
    },
    max_ongoing_requests=2,
    health_check_timeout_s=120,
)
@serve.ingress(api)
class SmolLM:
    def __init__(self):
        import mlflow
        import torch

        torch.set_num_threads(2)
        t0 = time.time()
        self.pipe = mlflow.transformers.load_model(MODEL_URI)
        print(f"model {MODEL_URI} loaded in {time.time() - t0:.1f}s", flush=True)

    @api.get("/v1/models")
    def models(self):
        return {"object": "list", "data": [{"id": "smollm", "object": "model", "root": MODEL_URI}]}

    @api.post("/v1/completions")
    def completions(self, req: CompletionRequest):
        out = self.pipe(req.prompt, max_new_tokens=req.max_tokens, do_sample=False, return_full_text=False)
        return {
            "id": str(uuid.uuid4()),
            "object": "text_completion",
            "created": int(time.time()),
            "model": req.model,
            "choices": [{"index": 0, "text": out[0]["generated_text"], "finish_reason": "length"}],
        }


app = SmolLM.bind()

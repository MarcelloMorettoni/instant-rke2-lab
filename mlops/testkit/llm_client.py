"""OpenAI-style completion client and small load generator, shared by every candidate.

  python llm_client.py once  <base_url> <model>
  python llm_client.py load  <base_url> <model> <concurrency> <seconds>
"""
import concurrent.futures
import statistics
import sys
import time

import requests

PROMPT = "ROMEO:\nWhat light through yonder"


def complete(base_url: str, model: str, timeout: int = 600):
    t0 = time.time()
    r = requests.post(
        f"{base_url}/v1/completions",
        json={"model": model, "prompt": PROMPT, "max_tokens": 24, "temperature": 0},
        timeout=timeout,
    )
    return r.status_code, time.time() - t0, (r.json()["choices"][0]["text"] if r.ok else r.text[:200])


if __name__ == "__main__":
    mode, base_url, model = sys.argv[1:4]
    if mode == "once":
        code, secs, text = complete(base_url, model)
        print(f"status={code} latency={secs:.1f}s text={text!r}")
    else:
        concurrency, seconds = int(sys.argv[4]), int(sys.argv[5])
        deadline, lat, errors = time.time() + seconds, [], 0

        def worker():
            out = []
            while time.time() < deadline:
                try:
                    code, secs, _ = complete(base_url, model, timeout=120)
                    out.append(secs if code == 200 else None)
                except Exception:
                    out.append(None)
            return out

        with concurrent.futures.ThreadPoolExecutor(concurrency) as pool:
            for res in pool.map(lambda _: worker(), range(concurrency)):
                lat += [x for x in res if x is not None]
                errors += sum(x is None for x in res)
        if lat:
            lat.sort()
            print(
                f"load: concurrency={concurrency} duration={seconds}s ok={len(lat)} errors={errors} "
                f"p50={statistics.median(lat):.1f}s p95={lat[int(len(lat) * 0.95) - 1]:.1f}s max={lat[-1]:.1f}s "
                f"throughput={len(lat) / seconds:.2f} req/s"
            )
        else:
            print(f"load: all {errors} requests failed")

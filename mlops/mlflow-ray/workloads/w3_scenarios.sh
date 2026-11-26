#!/usr/bin/env bash
# W3 follow-up scenarios on MLflow + Ray, mirroring the Kubeflow ones.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"
NS="${NS:-mr-alpha}"; HERE="$(dirname "${BASH_SOURCE[0]}")"
kit() { kubectl -n "${NS}" exec -i deploy/kit -c kit -- python -W ignore "$@"; }

echo "== registry and endpoint after run 1"
kit - <<'PY'
import mlflow, requests, tabular
c = mlflow.MlflowClient()
for mv in c.search_model_versions("name='sensor-fault'"):
    print("MODEL sensor-fault version", mv.version, "aliases", mv.aliases, mv.tags, "run", mv.run_id[:8])
exp = c.get_experiment_by_name("w3-continuous-training")
for r in c.search_runs([exp.experiment_id], order_by=["metrics.accuracy DESC"]):
    print("  trial", r.info.run_name, {k: round(v, 4) for k, v in r.data.metrics.items()})
df = tabular.gen_batch(99, 5)
r = requests.post("http://sensor-fault-serve-svc:8000/", json={"instances": df[tabular.FEATURES].values.tolist()}, timeout=60)
print("PREDICT", r.status_code, r.text[:120], "expected", df.fault.tolist())
PY

echo "== run 2: no new data"
"${HERE}/run-workflow.sh" "${NS}" w3-run-2-no-new-data || true

echo "== run 3: bad batch"
kit -c "
import os,s3,tabular
s3.put_bytes(os.environ['S3_BUCKET'],'datasets/w3/batch-900-bad.csv',tabular.to_csv_bytes(tabular.gen_batch(9).drop(columns=['pressure'])))"
"${HERE}/run-workflow.sh" "${NS}" w3-run-3-bad-data || true
kit -c "
import os,s3; s3.client().delete_object(Bucket=os.environ['S3_BUCKET'],Key='datasets/w3/batch-900-bad.csv'); print('bad batch removed')"

echo "== continuous training: cron every 2 min, two drifted batches waiting, then a timed third"
kit -c "
import os,s3,tabular
for i in (3,4): s3.put_bytes(os.environ['S3_BUCKET'],f'datasets/w3/batch-{i:03d}.csv',tabular.to_csv_bytes(tabular.gen_batch(i,drift=1.5)))"
kubectl -n "${NS}" patch cronworkflow w3-ct-every-2min --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
echo "$(date -u +%T) cron enabled"
until [[ "$(kit -c "import mlflow;print(len(mlflow.MlflowClient().search_model_versions(\"name='sensor-fault'\")))" 2>/dev/null | tail -1)" -ge 2 ]]; do sleep 10; done
echo "$(date -u +%T) version 2 registered (batches 1-4)"
kit - 5 < "${HERE}/w3_ct_measure.py"
kubectl -n "${NS}" patch cronworkflow w3-ct-every-2min --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
kubectl -n "${NS}" get workflow --sort-by=.metadata.creationTimestamp -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,START:.status.startedAt,END:.status.finishedAt'

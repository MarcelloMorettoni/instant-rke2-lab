"""What CI does on every push (run by .gitea/workflows/train.yaml in the project's CI runner).

  1. Compile pipeline.py.
  2. Upload it to Kubeflow Pipelines as a new version, named after the git commit.
  3. Start one run now with retrain=yes, because the code changed.
  4. Point the schedule at the new version: the recurring run that checks for new
     data every 2 minutes. It is switched off while the run of step 3 takes the
     current data, so the two never train on the same commit.

  python ci/deploy.py <git commit>
"""
import subprocess
import sys
import time

import kfp

PIPELINE, EXPERIMENT, SCHEDULE = "my-model-training", "my-model", "my-model-watch-data"
commit = sys.argv[1]
short = commit[:8]

subprocess.run([sys.executable, "pipeline.py", "pipeline.yaml"], check=True)

client = kfp.Client()  # in-cluster: project ServiceAccount token
namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
experiment = client.create_experiment(EXPERIMENT, namespace=namespace)  # returns the existing one if it is there

existing = [p for p in client.list_pipelines(namespace=namespace, page_size=100).pipelines or [] if p.display_name == PIPELINE]
if existing:
    pipeline_id = existing[0].pipeline_id
else:
    pipeline_id = client.upload_pipeline("pipeline.yaml", pipeline_name=PIPELINE, namespace=namespace).pipeline_id
version = client.upload_pipeline_version("pipeline.yaml", pipeline_version_name=f"commit-{short}", pipeline_id=pipeline_id)
print(f"pipeline {PIPELINE}: new version commit-{short}")

# Switch the current schedule off (a run it has in flight finishes normally) and
# remove the ones switched off by earlier pushes.
for job in client.list_recurring_runs(experiment_id=experiment.experiment_id, page_size=100).recurring_runs or []:
    if job.display_name == SCHEDULE:
        if job.status == "ENABLED":
            client.disable_recurring_run(job.recurring_run_id)
        else:
            client.delete_recurring_run(job.recurring_run_id)

run = client.run_pipeline(
    experiment.experiment_id, f"commit-{short}", pipeline_id=pipeline_id, version_id=version.pipeline_version_id,
    params={"retrain": "yes", "git_commit": commit}, enable_caching=False,
)
print(f"started run commit-{short}: Kubeflow console -> Runs")

print("waiting for its first step (detect-change) before the schedule goes back on", flush=True)
deadline = time.time() + 240
while time.time() < deadline:
    detail = client.get_run(run.run_id)
    steps = {t.display_name: t.state for t in (detail.run_details.task_details if detail.run_details else None) or []}
    if steps.get("detect-change") in ("SUCCEEDED", "FAILED") or detail.state in ("SUCCEEDED", "FAILED", "CANCELED"):
        break
    time.sleep(5)

client.create_recurring_run(
    experiment.experiment_id, SCHEDULE, cron_expression="0 */2 * * * *", max_concurrency=1, no_catchup=True,
    pipeline_id=pipeline_id, version_id=version.pipeline_version_id, params={"git_commit": commit}, enable_caching=False,
)
print(f"schedule {SCHEDULE}: every 2 minutes, on version commit-{short}")

"""What CI does on every push (run by .gitea/workflows/train.yaml in the project's CI runner).

  1. Compile pipeline.py: the training pipeline and the watch pipeline.
  2. Upload both to Kubeflow Pipelines as a new version, named after the git commit.
  3. For every data branch in data-branches.txt: start one training run now,
     because the code changed.
  4. For every data branch: a schedule that runs the watch pipeline every 2
     minutes. It starts a training run (on the new pipeline version) when the
     branch has a new lakeFS commit. The schedules are switched off while the
     runs of step 3 take the current data, so the two never train on the same commit.

  python ci/deploy.py <git commit>
"""
import json
import os
import re
import subprocess
import sys
import time

import kfp

# The names are fixed for the lesson; the environment variables exist to try a change beside it.
PIPELINE = os.environ.get("PIPELINE_NAME", "my-model-training")
WATCH = os.environ.get("WATCH_PIPELINE_NAME", "my-model-watch")
EXPERIMENT = os.environ.get("EXPERIMENT_NAME", "my-model")
SCHEDULE = os.environ.get("SCHEDULE_NAME", "my-model-watch-data")
EXTRA_PARAMS = json.loads(os.environ.get("PIPELINE_PARAMS", "{}"))
commit = sys.argv[1]
short = commit[:8]

branches = [line.strip() for line in open("data-branches.txt") if line.strip() and not line.startswith("#")] or ["main"]


def suffix(branch: str) -> str:
    """"" for main, "-<branch>" for the others: used in run and schedule names."""
    return "" if branch == "main" else "-" + re.sub("[^a-z0-9]+", "-", branch.lower()).strip("-")


subprocess.run([sys.executable, "pipeline.py", "pipeline.yaml", "watch.yaml"], check=True)

client = kfp.Client()  # in-cluster: project ServiceAccount token
namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
experiment = client.create_experiment(EXPERIMENT, namespace=namespace)  # returns the existing one if it is there



def publish(name: str, package: str):
    """New version commit-<short> of the pipeline `name` (created on the first push). Returns (pipeline id, version id)."""
    existing = [p for p in client.list_pipelines(namespace=namespace, page_size=100).pipelines or [] if p.display_name == name]
    pid = existing[0].pipeline_id if existing else client.upload_pipeline(package, pipeline_name=name, namespace=namespace).pipeline_id
    # The same commit again (the workflow started by hand) is the same code: reuse its version.
    for v in client.list_pipeline_versions(pid, page_size=100, sort_by="created_at desc").pipeline_versions or []:
        if v.display_name == f"commit-{short}":
            print(f"pipeline {name}: version commit-{short} is already there")
            return pid, v.pipeline_version_id
    vid = client.upload_pipeline_version(package, pipeline_version_name=f"commit-{short}", pipeline_id=pid).pipeline_version_id
    print(f"pipeline {name}: new version commit-{short}")
    return pid, vid


pipeline_id, version_id = publish(PIPELINE, "pipeline.yaml")
watch_id, watch_version_id = publish(WATCH, "watch.yaml")
print(f"data branches: {', '.join(branches)}")

# Switch the current schedules off (a run they have in flight finishes normally)
# and remove the ones switched off by earlier pushes. This also removes the
# schedule of a branch that is no longer in data-branches.txt.
for job in client.list_recurring_runs(experiment_id=experiment.experiment_id, page_size=100).recurring_runs or []:
    if job.display_name == SCHEDULE or job.display_name.startswith(SCHEDULE + "-"):
        if job.status == "ENABLED":
            client.disable_recurring_run(job.recurring_run_id)
        else:
            client.delete_recurring_run(job.recurring_run_id)

runs = []
for branch in branches:
    name = f"commit-{short}{suffix(branch)}"
    runs.append(
        client.run_pipeline(
            experiment.experiment_id, name, pipeline_id=pipeline_id, version_id=version_id,
            params={**EXTRA_PARAMS, "git_commit": commit, "data_branch": branch}, enable_caching=False,
        )
    )
    print(f"started run {name} (data branch {branch}): Kubeflow console -> Runs")

print("waiting for their first step (detect-change) before the schedules go back on", flush=True)
deadline = time.time() + 240
for run in runs:
    while time.time() < deadline:
        detail = client.get_run(run.run_id)
        steps = {t.display_name: t.state for t in (detail.run_details.task_details if detail.run_details else None) or []}
        if steps.get("detect-change") in ("SUCCEEDED", "FAILED") or detail.state in ("SUCCEEDED", "FAILED", "CANCELED"):
            break
        time.sleep(5)

for branch in branches:
    client.create_recurring_run(
        experiment.experiment_id, SCHEDULE + suffix(branch), cron_expression="0 */2 * * * *", max_concurrency=1, no_catchup=True,
        pipeline_id=watch_id, version_id=watch_version_id, enable_caching=False,
        params={
            **EXTRA_PARAMS, "git_commit": commit, "data_branch": branch,
            "experiment_id": experiment.experiment_id, "pipeline_id": pipeline_id, "pipeline_version_id": version_id,
        },
    )
    print(f"schedule {SCHEDULE}{suffix(branch)}: watches data branch {branch} every 2 minutes, trains with version commit-{short}")

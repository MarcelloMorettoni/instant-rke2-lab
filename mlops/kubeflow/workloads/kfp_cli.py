"""Tiny KFP driver used from the kit pod: run | schedule | wait | runs."""
import sys
import time

import kfp

EXPERIMENT = "w3"
client = kfp.Client()  # in-cluster: ml-pipeline.kubeflow + projected SA token
namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()


def experiment_id():
    return client.create_experiment(EXPERIMENT, namespace=namespace).experiment_id


def wait(run_id, timeout=1500):
    start = time.time()
    run = client.wait_for_run_completion(run_id, timeout=timeout, sleep_duration=5)
    print(f"run {run_id} state={run.state} wall={time.time() - start:.0f}s")
    for t in sorted(run.run_details.task_details or [], key=lambda t: t.create_time):
        if t.display_name and not t.display_name.endswith("-driver"):
            print(f"  {t.display_name:<28} {t.state}")
    return run.state


cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "run":
    package, name = args[0], args[1]
    params = dict(a.split("=", 1) for a in args[2:])
    run = client.create_run_from_pipeline_package(
        package, arguments=params, run_name=name, experiment_name=EXPERIMENT, namespace=namespace, enable_caching=False
    )
    print("run_id", run.run_id)
    sys.exit(0 if wait(run.run_id) == "SUCCEEDED" else 1)
elif cmd == "schedule":
    package, name, cron = args[0], args[1], args[2]
    params = dict(a.split("=", 1) for a in args[3:])
    job = client.create_recurring_run(
        experiment_id(), name, cron_expression=cron, pipeline_package_path=package, max_concurrency=1,
        no_catchup=True, enable_caching=False, params=params,
    )
    print("recurring_run_id", job.recurring_run_id)
elif cmd == "unschedule":
    for j in client.list_recurring_runs(experiment_id=experiment_id()).recurring_runs or []:
        client.delete_recurring_run(j.recurring_run_id)
        print("deleted", j.display_name)
elif cmd == "runs":
    for r in client.list_runs(experiment_id=experiment_id(), sort_by="created_at desc", page_size=20).runs or []:
        print(r.created_at.strftime("%H:%M:%S"), r.state, r.display_name, r.run_id)

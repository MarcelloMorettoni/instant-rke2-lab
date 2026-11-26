# Part 2: MLflow + Ray

You work in the project `mr-alpha` (`$MR`). Do [part 0](README.md#0-start-the-lab)
first. Run commands from the repository root.

This stack is four separate installs. Keep that in mind as you go: each step
below is a different tool with its own login or none at all.

| Step | Flow stage | Component |
|---|---|---|
| 2.1 | ③ Track experiments | MLflow Tracking |
| 2.2 | ② Develop | JupyterHub (added) |
| 2.3 | ④ Tune & train at scale | Ray Train on KubeRay |
| 2.4 | ⑤ Training pipeline | Argo Workflows (added), with Ray Tune inside |
| 2.5 | ⑥ Model registry | MLflow Model Registry |
| 2.6 | ⑦ Serve | Ray Serve |

## 2.1 Look around MLflow

1. Open http://localhost:5001. The browser asks for a user name and password:
   `mr-alpha` and its password from `mlops/training/lab.sh logins`.
2. **Experiments**: `w2-lm-finetune` (the fine-tuning runs) and
   `w3-continuous-training` (one run per hyperparameter trial).
3. Open `w3-continuous-training`, tick a few runs, **Compare**: parameters next
   to accuracy.
4. Open one run. **Overview** shows parameters, metrics and tags; look for the
   tag `data_uri` (the exact lakeFS commit the run trained on) and the
   **Datasets used** entry. **Artifacts** holds the model.
5. **Models → sensor-fault**: the versions, and the alias `champion` on the
   newest one.

What to notice: tracking and registry are one tool, and every model version
links back to the run that produced it.

## 2.2 A notebook on JupyterHub

1. Open http://localhost:8081/hub/signup and create an account: any user name,
   password of at least 10 characters. Sign-up is open in the lab.
2. Log in at http://localhost:8081. Your server starts (about 30 s; longer the
   first time on a node that has not pulled the image).
3. New **Python 3** notebook.

Cell 1:

```python
%pip install -q mlflow-skinny==3.18.0 scikit-learn==1.6.1
```

Cell 2. JupyterHub only knows the MLflow address, not who you are, so you give
the project's MLflow account by hand:

```python
import getpass, os
os.environ["MLFLOW_TRACKING_USERNAME"] = "mr-alpha"
os.environ["MLFLOW_TRACKING_PASSWORD"] = getpass.getpass("MLflow password for mr-alpha: ")
```

Cell 3: paste the content of
[mlflow-ray/notebook_tracking.py](mlflow-ray/notebook_tracking.py) and run it.

Expected: three lines `max_depth=… accuracy=…`. In MLflow the experiment
**training-jupyterhub-notebook** has three runs.

What to notice: the hub account, the MLflow account and the project are three
unrelated things here, and all hub users share one namespace. In Kubeflow the
notebook was created inside your project. This is the identity gap from the
findings.

If the server stays "pending": the cluster is full. Finish or delete running
jobs and click **Start My Server** again.

## 2.3 Distributed training with a Ray job

A `RayJob` creates a throw-away Ray cluster (one head, two workers, one per
worker VM), runs the training script on it and removes the cluster afterwards.
Read [mlflow-ray/rayjob.yaml](mlflow-ray/rayjob.yaml) first: the script is
`entrypoint`, the packages are `runtimeEnvYAML`, the cluster is `rayClusterSpec`.

```bash
kubectl -n $MR apply -f mlops/training/mlflow-ray/rayjob.yaml
```

```bash
kubectl -n $MR get rayjob training-finetune; kubectl -n $MR get pods -o wide | grep training-finetune
```

The Ray dashboard of this job's cluster, in a second terminal (after
`source mlops/training/env.sh`). Leave it running and open http://localhost:8266:

```bash
kubectl -n $MR port-forward svc/$(kubectl -n $MR get rayjob training-finetune -o jsonpath='{.status.rayClusterName}')-head-svc 8266:8265
```

In the dashboard: **Jobs** shows the running script and its log, **Cluster**
the head and two workers with their CPU use.

The job's log from the terminal (Ctrl-C to stop):

```bash
kubectl -n $MR logs -f -l batch.kubernetes.io/job-name=training-finetune
```

Expected: about 3 minutes installing packages on every node, then the training
steps, then `SUCCEEDED` after 6–8 minutes in total. In MLflow: experiment
**w2-lm-finetune**, newest run, **Model metrics**: the loss curve, and a
registered model `smollm2-135m-shakespeare` with a new version.

The Ray cluster is removed 2 minutes after the job ends. Wait until only the
`Completed` submitter pod is left before you go on, or the next step finds no
free CPU:

```bash
kubectl -n $MR get pods | grep training-finetune
```

What to notice: the same training code as Kubeflow's TrainJob, but no sidecar
workaround, and tracking is built in. The price is the package installation on
every node, which a pre-built image would remove.

## 2.4 The pipeline: Argo Workflows driving Ray

MLflow and Ray have no pipeline engine, so Argo Workflows runs the steps:
detect new data → validate → RayJob (Ray Tune search, train, evaluate, quality
gate, register) → deploy to Ray Serve → verify the endpoint. The definition is
[mlflow-ray/workloads/w3_workflow.yaml](../mlflow-ray/workloads/w3_workflow.yaml).

```bash
mlops/mlflow-ray/workloads/run-workflow.sh $MR my-first-run
```

Expected after about 40 s: `phase=Succeeded`, `detect Succeeded` and the other
four steps `Skipped`. No data is newer than the last trained model, so nothing
was trained. You make it train in [part 3](03-lakefs.md#34-new-data--new-model-on-mlflow--ray).

```bash
kubectl -n $MR get workflows --sort-by=.metadata.creationTimestamp | tail -5
```

There is no pipeline UI in this stack: the Argo server is not installed, so
runs are inspected with `kubectl`. Kubeflow gave you a graph for free.

## 2.5 Model registry

```bash
mr-kit - < mlops/training/mlflow-ray/registry.py
```

Expected: versions 1 to 6 or more, each with its accuracy and data version, and
`champion is version …`.

In the UI (**Models → sensor-fault**) move the alias by hand to see what a
promotion is: open an older version, **Aliases → Add**, type `champion`, save.
Run the script again: `champion` moved. Put it back on the newest version when
done; the endpoint in 2.6 keeps serving the version it loaded until the next
pipeline deploy.

## 2.6 Serve with Ray Serve

```bash
kubectl -n $MR get rayservices
```

Five predictions from the tabular model:

```bash
mr-kit - < mlops/training/mlflow-ray/predict.py
```

Expected: `status 200`, predictions equal to `expected`, and the model version
it serves.

Its Ray cluster is the one behind http://localhost:8265: open **Serve** to see
the deployment and its replica.

The language model. Its workers are scaled to zero, so the first request waits
for a worker pod that installs PyTorch (110–130 s):

```bash
mr-kit /testkit/llm_client.py once http://smollm-serve-svc.$MR.svc.cluster.local:8000 smollm
```

Watch the worker leave about 200 s after the last request (Ctrl-C to stop):

```bash
kubectl -n $MR get pods -l ray.io/group=llm -w
```

Then look at what stays:

```bash
kubectl -n $MR get pods | grep smollm
```

What to notice: the head pod (1 CPU, 2 GiB) never goes away. KServe went fully
to zero.

## What you used

| You did | With | Stage |
|---|---|---|
| Compared runs | MLflow Tracking | ③ |
| Notebook | JupyterHub (added) | ② |
| 2-node fine-tune | Ray Train on a RayJob | ④ |
| Pipeline run | Argo Workflows (added) | ⑤ |
| Versions and alias | MLflow Model Registry | ⑥ |
| Predictions, scale to zero | Ray Serve | ⑦ |

Next: [Part 3: lakeFS](03-lakefs.md).

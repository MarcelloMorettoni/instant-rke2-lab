# Part 1: Kubeflow

You work in the project `kubeflow-user-example-com` (`$KF`), as `user@example.com`.
Do [part 0](README.md#0-start-the-lab) first. Run commands from the repository root.

What you will touch, in flow order:

| Step | Flow stage | Kubeflow component |
|---|---|---|
| 1.2 | ② Develop | Notebooks |
| 1.3 | ③ Track experiments | none of its own: MLflow |
| 1.4 | ⑤ Training pipeline | Kubeflow Pipelines |
| 1.5 | ④ Tune | Katib |
| 1.6 | ④ Train at scale | Kubeflow Trainer |
| 1.7 | ⑤ Training pipeline | Kubeflow Pipelines, the real one |
| 1.8 | ⑥ Model registry | Model Registry |
| 1.9 | ⑦ Serve | KServe |

## 1.1 Log in and look around

1. Open http://localhost:8080 and click **Sign in with Dex**.
2. Log in with `user@example.com` / `12341234`.
3. Top left, the namespace selector shows `kubeflow-user-example-com`. That
   namespace is your project: everything you create lands there.
4. The left menu is the whole platform: Notebooks, Katib Experiments, KServe
   Endpoints, Pipelines, Runs, Recurring Runs, Model Registry.

What to notice: one login and one menu for everything. That is Kubeflow's main
selling point over MLflow + Ray.

## 1.2 Start a notebook server

1. **Notebooks → New Notebook**.
2. Name: `my-notebook`. Leave the image on the default `jupyter-scipy`.
3. CPU `0.5`, memory `1` Gi.
4. Open **Advanced Options → Configurations** and tick both entries:
   - *Allow access to Kubeflow Pipelines*
   - *MLflow tracking server and credentials*
5. **Launch**. Wait until the status turns green (1–3 minutes: the image is
   already on the workers), then **Connect**.

The two configurations are `PodDefault` objects
([kubeflow/poddefaults.yaml](kubeflow/poddefaults.yaml)). The first ships with
Kubeflow; the second is ours, because Kubeflow has no MLflow wiring. Without
them the notebook cannot submit pipelines or reach MLflow.

Check from the terminal:

```bash
kubectl -n $KF get notebooks,pods -l notebook-name=my-notebook
```

## 1.3 Track experiments from the notebook

In JupyterLab open a new **Python 3** notebook.

Cell 1, the MLflow client (the image has scikit-learn and the Pipelines SDK,
not MLflow). Ignore the red `protobuf` dependency warning.

```python
%pip install -q mlflow-skinny==3.18.0
```

Cell 2: paste the content of
[kubeflow/notebook_tracking.py](kubeflow/notebook_tracking.py) and run it.
It trains three small models and logs each as an MLflow run.

Expected: three lines like `max_depth=2 accuracy=0.99…`, each followed by a
"View run" link (the link is a cluster-internal address; use the URL below).

Now look at the runs:

1. Open http://localhost:5001 and log in as `kubeflow-user` (password from
   `mlops/training/lab.sh logins`).
2. Open the experiment **training-kubeflow-notebook**.
3. Tick the three runs and click **Compare**.

What to notice: tracking works, but with a second login and a second UI, and it
only worked because we injected the credentials ourselves.

## 1.4 Your first pipeline, from the notebook

Cell 3: paste the content of
[kubeflow/notebook_pipeline.py](kubeflow/notebook_pipeline.py) and run it.

It defines two components (`train`, `pick_best`), wires them into a pipeline and
submits it. Each step runs as its own pod and installs its packages first, so
allow 2–4 minutes. The cell ends with `state: SUCCEEDED`.

While it runs, in the Kubeflow UI:

1. **Runs** → `hello-from-notebook`.
2. The graph shows two `train` steps in parallel, then `pick-best`.
3. Click a step: **Logs** shows its output, **Input/Output** its parameters.

From the terminal you see the same run as pods:

```bash
kubectl -n $KF get pods --sort-by=.metadata.creationTimestamp | tail -8
```

## 1.5 Hyperparameter search with Katib

The experiment tries 2 × 2 combinations of `n_estimators` and `max_depth`, two
at a time. Each trial is a Kubernetes Job.

```bash
sed 's/sensor-fault-hpo/training-hpo/' mlops/kubeflow/workloads/katib_experiment.yaml | kubectl -n $KF apply -f -
```

Watch the trials (Ctrl-C to stop). All four finish in about 2.5 minutes.

```bash
kubectl -n $KF get trials.kubeflow.org -w
```

The winner:

```bash
kubectl -n $KF get experiment.kubeflow.org training-hpo -o json | jq '.status.currentOptimalTrial'
```

Expected: `n_estimators=100`, `max_depth=2`, accuracy `0.8840`.

In the UI: **Katib Experiments → training-hpo** shows the trials as a
parallel-coordinates plot and the best one highlighted.

## 1.6 Distributed training with Kubeflow Trainer

A `TrainJob` fine-tunes a 135-million-parameter language model on two nodes,
one pod per worker VM. Read [kubeflow/trainjob.yaml](kubeflow/trainjob.yaml)
first: note `numNodes: 2` and the annotation that switches the Istio sidecar
off. Without that annotation the job hangs (finding 8 on the Kubeflow page).

```bash
kubectl -n $KF apply -f mlops/training/kubeflow/trainjob.yaml
```

```bash
kubectl -n $KF get trainjob training-finetune; kubectl -n $KF get pods -l jobset.sigs.k8s.io/jobset-name=training-finetune -o wide
```

Follow the first node's log (Ctrl-C to stop):

```bash
kubectl -n $KF logs -f -l jobset.sigs.k8s.io/jobset-name=training-finetune,batch.kubernetes.io/job-completion-index=0
```

Expected: package installation for about 2 minutes, then `step 5 loss …` up to
step 30, `model uploaded to s3://…` and `registered smollm2-135m-shakespeare v…`.
The job is `Complete` after about 4 minutes.

In MLflow (http://localhost:5001, user `kubeflow-user`): experiment
**kubeflow-w2-lm-finetune**, run `training-finetune`, **Model metrics** tab: the
loss curve.

## 1.7 The real pipeline: validate, train, evaluate, gate, register, deploy

This is the continuous-training pipeline from the POC
([kubeflow/workloads/w3_pipeline.py](../kubeflow/workloads/w3_pipeline.py)).
It is driven from the project's workstation pod.

Compile it (the pod's environment says the data lives in lakeFS, so the compiled
pipeline reads from lakeFS):

```bash
kubectl -n $KF exec -i deploy/kit -c kit -- sh -c 'cat > /tmp/w3_pipeline.py && python -W ignore /tmp/w3_pipeline.py /tmp/w3_pipeline.yaml' < mlops/kubeflow/workloads/w3_pipeline.py
```

Run it:

```bash
kf-kit /workloads/kfp_cli.py run /tmp/w3_pipeline.yaml my-first-run bucket=kf-sensor-data
```

Expected after about 70 s: `state=SUCCEEDED` with only `detect-new-data` in the
list. The pipeline found no data newer than the last trained model, so it
skipped training. That is the retrain logic working. In **Runs → my-first-run**
the graph shows the skipped branch greyed out.

You make it train for real in [part 3](03-lakefs.md#33-new-data--new-model-on-kubeflow),
by committing new data.

If the workstation pod was restarted, `/tmp/w3_pipeline.yaml` is gone: compile again.

## 1.8 Model registry

```bash
kf-kit - < mlops/training/kubeflow/registry.py
```

Expected: model `sensor-fault` with versions `v1`…`v5` (accuracy, data version,
pipeline run ID) and `smollm2-135m-shakespeare` with the version your TrainJob
just registered.

The **Model Registry** entry in the Kubeflow menu opens its UI, but it lists
nothing for your project: the registry is one shared instance in the `kubeflow`
namespace that normal users cannot select (finding 4). The REST API used by the
script is open inside the cluster.

## 1.9 Serve with KServe

Two endpoints already exist:

```bash
kubectl -n $KF get inferenceservices
```

Ask the tabular model for five predictions:

```bash
kf-kit - < mlops/training/kubeflow/predict.py
```

Expected: `status 200`, and `predicted` equal to `expected`.

Now the language model. It is scaled to zero, so the first request starts a pod
(25–145 s):

```bash
kf-kit /testkit/llm_client.py once http://smollm-predictor.$KF.svc.cluster.local/openai smollm
```

Watch it go back to zero, about 100 s after the last request (Ctrl-C to stop):

```bash
kubectl -n $KF get pods -l serving.kserve.io/inferenceservice=smollm -w
```

In the UI: **KServe Endpoints** lists both, with their URL and status.

What to notice: nothing is left running at zero. Compare with Ray Serve in part 2.

## What you used

| You did | With | Stage |
|---|---|---|
| Notebook server | Kubeflow Notebooks | ② |
| Logged runs | MLflow (added) | ③ |
| Pipeline from Python | Kubeflow Pipelines | ⑤ |
| 4-trial search | Katib | ④ |
| 2-node fine-tune | Kubeflow Trainer | ④ |
| Listed versions | Model Registry | ⑥ |
| Predictions, scale to zero | KServe | ⑦ |

Next: [Part 2: MLflow + Ray](02-mlflow-ray.md).

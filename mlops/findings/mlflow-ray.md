# POC findings: MLflow + Ray

> Status: DRAFT · Last updated: 26 Nov 2026

| Field | Value |
|---|---|
| Candidate | MLflow + Ray |
| Versions tested | MLflow 3.18.0, Ray 2.60.1 on KubeRay 1.7.3; add-ons in section 2 |
| POC owner | [name] |
| Jira ticket | [NLAIF-xxx] |
| Timebox | [planned days] · Used: about half a day of hands-on lab time, shared with the Kubeflow candidate |
| Dates | 25 Nov 2026 – 26 Nov 2026 |
| Environment | RKE2 lab cluster on one desktop: 3 VMs, 16 vCPU / 40 GiB in total, no GPU, no SRAM; details in section 2 |
| Overall verdict | Viable with conditions |

Read this first:

- The lab has **no GPU and no SRAM**. W1, W2 and W4 were run CPU-sized with a 135M-parameter language model; the GPU, vLLM and SRAM parts are recorded as "Not tested".
- Only the Kubernetes deployment (KubeRay) was tested. Ray on VMs and on Slurm were not.
- Evidence paths are relative to `mlops/` in the `instant-rke2-lab` repository. Nothing is committed yet, so there are no commit links.
- All timings for this candidate were taken while the worker VMs' disks sat on a USB hard drive (a lab storage problem). Kubeflow's W2 and W4 were measured under the same conditions; its W1, W3 and W5 ran on NVMe, so those comparisons slightly favour Kubeflow.

## 1. Summary

Verdict: Viable with conditions. The core (tracking, registry, distributed training, tuning, serving) worked with little friction and a small footprint, and each piece installed in under a minute. What the hypothesis called gaps are real: we added JupyterHub and Argo Workflows, and we wrote the whole project/tenancy layer ourselves. Identity is the weak point: three separate logins and no single sign-on in open-source MLflow.

What worked well:

- Small and fast to stand up: KubeRay in 25 s, Argo in 8 s, JupyterHub in 25 s; 7 platform pods at idle against Kubeflow's 56 ([04-idle-footprint.txt](../evidence/mlflow-ray/04-idle-footprint.txt)).
- Distributed training and tuning are plain Python: the same training function ran under Ray Train on 2 nodes with an identical loss curve to the Kubeflow run, and no mesh surprises ([w2-rayjob.log](../evidence/mlflow-ray/w2-rayjob.log)).
- MLflow as tracker and registry: runs, per-step metrics, versions, tags and a "champion" alias, with per-user permissions that held up between two projects ([w3-scenarios.log](../evidence/mlflow-ray/w3-scenarios.log), [w5-isolation.log](../evidence/mlflow-ray/w5-isolation.log)).
- The retraining loop worked end to end once Argo was added, including an in-place model swap on the serving endpoint ([w3-run-1.log](../evidence/mlflow-ray/w3-run-1.log)).
- Upgrading the Ray operator took 14 s with 60 of 60 requests to a live endpoint succeeding ([10-kuberay-upgrade.log](../evidence/mlflow-ray/10-kuberay-upgrade.log)).

What did not work, or was harder than expected:

- There is no project object. Namespace, quota, network policy, RBAC, MLflow user and storage identity are a script we wrote and now own (issue 12).
- No single sign-on: JupyterHub, MLflow and the Ray dashboard each have their own access model, and MLflow's built-in authentication is basic auth marked experimental (issues 7, 15).
- "Scale to zero" on Ray Serve stops the workers but keeps one head pod per service running (issue 10).
- Without pre-built images, every job and every cold start reinstalls its Python packages: 110 s cold start against 23–144 s for KServe (issue 8).
- JupyterHub's default network policy blocks notebook spawning on Cilium until a Cilium policy is added (issue 14).

Hypotheses that changed: none of the nine stage ratings moved. Two got sharper: stage 7 is Native but scale-to-zero is only partial, and stage 9 is Partial at the low end (everything except MLflow's permissions is self-built).

Conditions for adopting it:

- We accept building and maintaining the tenancy layer, or we find one (for example a namespace-as-a-service operator).
- SRAM login is proven for JupyterHub (OIDC) and a solution is chosen for MLflow (plugin or an authenticating proxy). Neither could be tested here.
- A CI pipeline that builds images, so jobs and endpoints do not install packages at start.
- A pipeline engine is chosen and owned (Argo Workflows worked).

Recommended next step: continue to a pilot with one research group, with the identity question (SRAM for JupyterHub and MLflow) as the first thing to prove, and repeat W2 and W4 on GPUs with vLLM. See the [comparison](comparison.md).

## 2. Setup

### 2.1 Environment

| Item | Value |
|---|---|
| Foundation | Kubernetes: RKE2 v1.36.6+rke2r1 on 3 KVM/libvirt VMs (Ubuntu 24.04) on one desktop host |
| Nodes | 3: cp1 (control plane + etcd) 4 vCPU / 8 GiB; worker1 and worker2 6 vCPU / 16 GiB each |
| GPUs | None exposed to the cluster. Not tested: type, sharing mode |
| Storage | Storage class `local-path` (node-local, ReadWriteOnce). Object storage: a single-pod SeaweedFS we deployed for MLflow artifacts and datasets |
| Identity | Local accounts: JupyterHub NativeAuthenticator, MLflow basic auth. SRAM not available |
| Network and access | Cilium 1.20.4. Access through `kubectl port-forward`. No DNS, no TLS |
| Isolation from other POCs | Shared cluster with Kubeflow, in separate namespaces (`mlflow`, `ray-system`, `argo`, `jhub`, projects `mr-alpha`, `mr-beta`). Kubeflow's Argo CRDs were already present, so Argo was installed on the same 3.7 line with an instance ID |

### 2.2 Components and versions

| Component | Version | Installed how | Notes |
|---|---|---|---|
| MLflow (tracking + registry) | 3.18.0 | plain manifests (`mlflow-ray/mlflow.yaml`) | Official image plus `pip install` of the PostgreSQL driver, boto3 and auth extras at start; basic auth on; 2 workers |
| PostgreSQL | 17 | manifests | MLflow metadata and auth database |
| SeaweedFS (S3) | 3.97 | manifests | Artifacts and datasets; one identity per project |
| KubeRay operator | 1.7.3 | Helm | RayJob, RayService, RayCluster, RayCronJob CRDs |
| Ray | 2.60.1 (`rayproject/ray:2.60.1-py311-cpu`) | image pulled by RayJob / RayService | Packages installed per job with `runtime_env` (no registry in the lab) |
| Argo Workflows (add-on for stage 5) | 3.7.11, chart 0.47.5 | Helm | Controller only, no UI server |
| JupyterHub (add-on for stage 2) | 5.5.5, chart 4.4.5 | Helm | Plus one CiliumNetworkPolicy |

All of these were the latest releases on the test date except Argo, held back to 3.7 by Kubeflow's CRDs on the shared cluster ([00-upstream-versions.txt](../evidence/00-upstream-versions.txt)).

### 2.3 Installation

| Measure | Value | Evidence |
|---|---|---|
| Effort to a working installation | MLflow: about 20 min including two fixes (database driver URI, memory). KubeRay 25 s, Argo 8 s, JupyterHub 25 s plus 10 min for the Cilium policy. Tenancy script: about 1 h to write. Hands-on effort about 2 h in total | install scripts in `mlflow-ray/`; [w1-first-login.log](../evidence/mlflow-ray/w1-first-login.log) |
| Steps that were not in the official docs | 3: MLflow image needs extra packages; MLflow needs fewer workers or more memory; JupyterHub needs a Cilium policy (the last is a known issue) | |
| Platform footprint at idle | 7 pods in 4 namespaces. Usage 0.02 CPU / 2.7 GiB (MLflow server 2.4 GiB of it); requests 0.75 CPU / 2.2 GiB. 4 Ray CRDs + 8 Argo CRDs, 3 PVCs. Plus one always-on head pod (1 CPU / 2 GiB requested) per Ray Serve service | [04-idle-footprint.txt](../evidence/mlflow-ray/04-idle-footprint.txt) |
| External services it needs | PostgreSQL and an S3 store for MLflow; nothing for Ray. We chose and installed both | |

Deviations from the documentation:

- `ghcr.io/mlflow/mlflow` has no PostgreSQL driver, no S3 client and no auth extras; we install them when the container starts. A real setup would build an image.
- MLflow 3.18 with its default four workers was OOM-killed at a 2 GiB limit. Runs with two workers and 3 GiB.
- The JupyterHub chart's hub NetworkPolicy allows the Kubernetes API by IP range, which Cilium does not match, so spawning times out. Added a CiliumNetworkPolicy (`mlflow-ray/jupyterhub-cilium.yaml`).
- Found later, while preparing the training (26 Nov): the same chart's notebook NetworkPolicy blocks every cluster-internal address, so a JupyterHub notebook could not reach MLflow. Added a NetworkPolicy for MLflow and its object store to the same file. The POC had only tested tracking from a Kubeflow notebook.
- Added for the training (26 Nov), not part of the tested POC: the Argo Workflows console (argo-server, no login, reached through a local port-forward only), a git server with CI (Gitea, [mlops/gitea](../gitea/)) and a NetworkPolicy so JupyterHub notebooks reach it. With these a push from a notebook starts the pipeline, and each model version carries the git commit and the lakeFS commit. The same trigger was built for Kubeflow; neither candidate has a git or data trigger of its own.
- The project NetworkPolicy must let the KubeRay operator reach each Ray head on port 8265, or RayJobs never report status.

## 3. Reference workloads

Code and data: `mlops/testkit/` (shared), `mlops/mlflow-ray/workloads/` (this candidate).

| # | Workload | Result | Time / effort | Notes | Evidence |
|---|---|---|---|---|---|
| W1 | GPU notebook session for a new user, from first login through SRAM | Workaround, for a CPU notebook with a local account. GPU and SRAM: Not tested | 26 s from login to a running notebook (18 s of it image pull) (HDD). Sign-up + login under 1 s | Needs JupyterHub (add-on) and a Cilium policy. First attempt failed before the policy | [w1-first-login.log](../evidence/mlflow-ray/w1-first-login.log) |
| W2 | Multi-node fine-tuning of a small open language model, tracked and registered | Works | 353 s wall for 2 nodes with images cached (85 s training) (HDD). First ever run adds about 3 min of image pull per node. Set-up: one RayJob YAML and one script | Tracked and registered in MLflow natively | [w2-attempt1.log](../evidence/mlflow-ray/w2-attempt1.log), [w2-rayjob.log](../evidence/mlflow-ray/w2-rayjob.log) |
| W3 | Training pipeline with automatic retrain on new data | Workaround (needs Argo Workflows) | Pipeline: about 225 lines of YAML and 125 lines of Python. First run 282 s. New data to new registered version: 378 s, served at 400 s, on a 2-minute schedule (HDD) | No data-event trigger: schedule plus a "detect new data" step | [w3-run-1.log](../evidence/mlflow-ray/w3-run-1.log), [w3-scenarios.log](../evidence/mlflow-ray/w3-scenarios.log) |
| W4 | vLLM endpoint for evaluation, with autoscaling and scale-to-zero | Workaround on CPU: Ray Serve with a hand-written OpenAI-style wrapper. vLLM: Not tested (needs a GPU) | Cold start 110 s, twice (HDD). Workers at zero 202 s after the last request; the head pod stays. 2 worker pods under load | 217 requests in 180 s at 6 concurrent, p50 3.6 s, no errors | [w4-rayserve-llm.log](../evidence/mlflow-ray/w4-rayserve-llm.log) |
| W5 | Two projects side by side: isolation, quotas, access control | Workaround (self-built) | New project: one script run, about 1.2 s. Writing the script: about 1 h | Isolation held on every check. JupyterHub users are outside this model | [w5-projects.log](../evidence/mlflow-ray/w5-projects.log), [w5-isolation.log](../evidence/mlflow-ray/w5-isolation.log) |

Notes per workload:

- W1: JupyterHub with self-service sign-up as a stand-in for SRAM. A new user signed up, logged in and had JupyterLab running in 26 s with a 5 GiB volume; an anonymous request is redirected to login. Surprises: all users' notebooks run in the one `jhub` namespace with no quota; the notebook gets the MLflow URL but no credentials, so linking a hub user to a project and an MLflow account would be another piece of glue; idle notebooks are culled after an hour by default.
- W2: RayJob with a throw-away cluster (head + 2 workers on 2 nodes) and Ray Train. Training itself took 85 s, the same as under Kubeflow, with an identical loss curve. The rest of the 353 s is cluster start, package install on every node and uploading the 540 MB model through MLflow. Two small stumbles, both in MLflow: logging a transformers model failed on a missing `torchvision` until requirements were given explicitly; nothing Ray-related.
- W3: Argo runs the light steps as containers and the heavy step as a RayJob that it creates and waits for. That job runs a 4-trial Ray Tune search, logs every trial to MLflow, registers the best model if it passes the accuracy gate and moves the "champion" alias. The deploy step re-applies the RayService with a new version marker and Ray Serve reloads the model in place; a verify step checks the endpoint answers with the champion version. Gates behave: no new data → 41 s; malformed batch → stopped at validation in 66 s. Stumbles: parallel trials racing to create the same MLflow experiment got "403 Permission denied" under basic auth; MLflow 3.18 refuses to save a tree model until its type is declared trusted. KubeRay also ships a RayCronJob resource, which would cover schedule-only cases without Argo (not tested).
- W4: Ray's own LLM serving is built on vLLM and needs a GPU, so we wrapped a transformers pipeline in a small FastAPI deployment (about 65 lines) loading the model from the MLflow registry. Autoscaling is set to 0–3 replicas and the Ray autoscaler adds and removes worker pods. The 110 s cold start is mostly the worker pod installing PyTorch; with a pre-built image it would be pod start plus model load. Worker pods of the service never report Ready when the HTTP proxy runs on the head only (cosmetic). The third replica was not added inside the 3-minute load window; not investigated.
- W5: `tenant.sh` creates the namespace, a quota with default limits, a same-project-only NetworkPolicy, a ServiceAccount with rights to Ray resources, an MLflow user and an object-store identity limited to the project's bucket. From project B with its own credentials: A's pods, serving endpoint and Ray dashboard are unreachable; A's experiments, runs, registered models and artifacts are invisible or denied in MLflow; A's bucket is denied. A pod without resource settings is accepted (default limits apply) and one over quota is rejected.

## 4. Coverage per stage of the flow

| Stage | Hypothesis (comparison page) | Observed | Changed? | What we used | Evidence |
|---|---|---|---|---|---|
| 1 Data | Partial | Partial | No | MLflow dataset tracking records name, digest, schema and source on a run; it does not store or version data. Ray Data was not exercised. Our own fingerprint and validation code did the work. Versioning added in a follow-up test with lakeFS: see [the add-on page](data-versioning-and-catalog.md) | [09-dataset-tracking.log](../evidence/mlflow-ray/09-dataset-tracking.log), [mlflow-ray-w3.log](../evidence/lakefs/mlflow-ray-w3.log) |
| 2 Develop | Gap | Gap | No | JupyterHub add-on | [w1-first-login.log](../evidence/mlflow-ray/w1-first-login.log) |
| 3 Tracking | Native | Native | No | MLflow Tracking from Ray Train, Ray Tune and (in the Kubeflow test) notebooks | [w2-rayjob.log](../evidence/mlflow-ray/w2-rayjob.log) |
| 4 Tune & train | Native | Native | No | Ray Train (2-node PyTorch), Ray Tune (grid search) | [w2-rayjob.log](../evidence/mlflow-ray/w2-rayjob.log), [w3-scenarios.log](../evidence/mlflow-ray/w3-scenarios.log) |
| 5 Pipelines | Gap | Gap | No | Argo Workflows add-on: WorkflowTemplate + CronWorkflow driving RayJobs | [w3-run-1.log](../evidence/mlflow-ray/w3-run-1.log) |
| 6 Registry | Native | Native | No | MLflow Model Registry: versions, tags, aliases, per-user permissions | [w3-scenarios.log](../evidence/mlflow-ray/w3-scenarios.log) |
| 7 Serving | Native | Native | No | Ray Serve through RayService, autoscaling, in-place reconfigure. Scale-to-zero leaves the head pod; LLM on CPU needed our own wrapper | [w4-rayserve-llm.log](../evidence/mlflow-ray/w4-rayserve-llm.log) |
| 8 Monitoring | Partial | Partial | No | Ray exposes Prometheus metrics and a dashboard per cluster; MLflow needs a flag to expose metrics; nothing collects them and there is no drift detection. MLflow evaluation and tracing were not exercised | [day2-static-checks.log](../evidence/day2-static-checks.log) |
| 9 Tenancy & identity | Partial | Partial | No | Our `tenant.sh` plus MLflow basic auth. No shared identity across JupyterHub, MLflow and Ray | [w5-isolation.log](../evidence/mlflow-ray/w5-isolation.log) |
| Count | 4 native, 3 partial, 2 gaps | 4 native, 3 partial, 2 gaps | | | |

## 5. Wrappers we had to build

| Wrapper | Type (light / complex) | Covers stage | Expected in hypothesis? | Build effort | Maintenance concern |
|---|---|---|---|---|---|
| JupyterHub install + Cilium policy | light | 2 | Yes | 0.5 h | Another Helm release to upgrade; no link from hub users to projects or MLflow accounts |
| Argo Workflows install, WorkflowTemplate, CronWorkflow | complex | 5 | Yes | 1.5 h | Pipeline definitions are YAML we own; second controller on a cluster that already has Argo |
| "Detect new data" step + schedule | light | 5 | No, new | 0.5 h (shared design with the Kubeflow one) | Polling; time to retrain is bounded by the schedule |
| Deploy-by-reconfigure step and endpoint verify step | light | 7 | No, new | 0.5 h | Tied to our RayService layout |
| OpenAI-style serving wrapper for CPU | light | 7 | No, new | 0.5 h | Disappears with GPUs and Ray's vLLM integration (not tested) |
| `tenant.sh`: namespace, quota, default limits, NetworkPolicy, RBAC, MLflow user, S3 identity | complex | 9 | Yes | 1 h, plus two bugs in our object-store handling | Our own tenancy model: every new component must be added to it |
| MLflow deployment: image extras, auth config, PostgreSQL, S3 | light | 3, 6 | No, new | 0.5 h | No official Helm chart was used; a custom image is the clean fix |
| Data validation and fingerprinting code | light | 1 | Yes | shared with Kubeflow | It is our code, not a data-versioning tool |
| lakeFS for data versioning, with an adapter in the test kit (follow-up test) | light | 1 | Yes | 0.5 h, shared with Kubeflow | Open-source lakeFS has a single user: no isolation between projects |
| Single sign-on across JupyterHub, MLflow, Ray dashboard (not built, required) | complex | 9 | Yes | not estimated | The largest open item |
| Image build pipeline for Ray jobs and services (not built, required) | light | 4, 7 | No, new | not estimated | Without it every start installs packages |
| Prometheus + Grafana (not built) | complex | 8 | Yes | not estimated | Separate stack to run |

## 6. Day-2 operations

| Check | Result | Effort | Evidence |
|---|---|---|---|
| Minor version upgrade (KubeRay 1.7.2 → 1.7.3) | Works: 14 s, 60 of 60 requests to a live Ray Serve endpoint succeeded, no head restarts. Helm does not upgrade CRDs, so a release that changes them needs one extra step. MLflow, Ray, Argo and JupyterHub upgrades: Not tested | 5 min | [10-kuberay-upgrade.log](../evidence/mlflow-ray/10-kuberay-upgrade.log) |
| Backup and restore of metadata (runs, registry, pipelines) | Works: one PostgreSQL dump restored into a scratch database with identical row counts for runs, metrics, params, experiments and model versions. Also to cover: auth database, artifact bucket, JupyterHub database | 10 min | [day2-backup-restore.log](../evidence/day2-backup-restore.log) |
| Recovery after a node failure | Partly tested, unplanned: the control-plane node stalled for about 25 minutes. The KubeRay operator restarted twice and recovered; the Ray job running at the time was lost and had to be resubmitted. A worker failure was not tested (node-local storage) | | [07-control-plane-stall-recovery.log](../evidence/kubeflow/07-control-plane-stall-recovery.log) |
| Platform metrics and logs available | Workaround: Ray head serves Prometheus metrics and a dashboard; MLflow needs `--expose-prometheus`; nothing scrapes them. Logs through `kubectl`; logs of a finished RayJob live in its submitter pod until it is cleaned up | | [day2-static-checks.log](../evidence/day2-static-checks.log) |
| Usage and cost per project visible | Fails: only quota counters per namespace | | [w5-isolation.log](../evidence/mlflow-ray/w5-isolation.log) |
| Energy per project visible | Fails: nothing shipped | | |
| Security: image scanning, policies, secrets handling | Mixed. Good: credentials are generated at install, MLflow denies by default, network policy per project. Not good: Ray's dashboard and job API accept any caller that can reach them (we rely on the NetworkPolicy); MLflow auth is basic auth and marked experimental; no image scanning or admission policy; Pod Security level is whatever we set | | [day2-static-checks.log](../evidence/day2-static-checks.log), [w5-isolation.log](../evidence/mlflow-ray/w5-isolation.log) |

## 7. Evaluation criteria

The comparison page I was given has stage ratings but no per-criterion ratings, so the hypothesis column is empty.

| Criterion | Hypothesis (comparison page) | Observed | Evidence and reasoning |
|---|---|---|---|
| Capability coverage (stages 1–9) | Not on the page provided | Medium | 4 native, 3 partial, 2 gaps. Two add-ons and a tenancy layer needed |
| Ease of use for researchers | Not on the page provided | Medium | Training, tuning and tracking are ordinary Python and the same code ran unchanged. But three tools with three logins, and pipelines are Argo YAML |
| Openness and governance | Not on the page provided | Strong | Apache 2.0 throughout; Linux Foundation and PyTorch Foundation projects, each led by one company. Not assessed further in the POC |
| Modularity | Not on the page provided | Strong | Four independent installs, each under a minute, each replaceable; the operator upgraded under a live service |
| Multi-tenancy and identity | Not on the page provided | Weak | Isolation held, but only because we built it. No single sign-on; MLflow auth is basic and experimental; JupyterHub users share one namespace |
| Upgrade and operational load | Not on the page provided | Medium | 7 pods, one database, Helm upgrades. Against that: the glue is ours, and images must be built |
| Community and momentum | Not on the page provided | Strong | Every component's latest release was days to weeks old on the test date |
| Platform independence | Not on the page provided | Medium | By design MLflow and Ray also run on VMs and Slurm, which is the reason to consider them. Only Kubernetes was tested, and the add-ons we used (KubeRay, Argo, the JupyterHub chart) are Kubernetes-only |
| SURF ecosystem fit (SRAM, storage, Snellius) | Not on the page provided | Not tested | No SRAM or SURF storage in the lab. JupyterHub has an OIDC authenticator; MLflow has none built in |
| Sovereignty (runs fully on SURF infrastructure) | Not on the page provided | Strong | Everything ran on our own cluster. Images and packages come from public registries and PyPI, so an air-gapped install needs mirrors |
| Sustainability (scale-to-zero, usage metrics) | Not on the page provided | Medium | Training clusters exist only while a job runs; notebooks are culled by default; low idle footprint. Serving keeps one head pod per service; no usage or energy metrics |
| FAIR-readiness (lineage, PIDs, export) | Not on the page provided | Medium | Each model version links to its run, parameters, metrics and data fingerprint; dataset digests can be recorded. No PIDs. Export not tested |
| Licence cost | Not on the page provided | Strong | None |

## 8. Candidate-specific checks

| Check | Result | Evidence |
|---|---|---|
| MLflow open-source authentication options for multiple tenants | Built in: basic auth with per-user permissions on experiments and registered models, default "no permissions". It isolated two projects on every check, including the artifact proxy. Limits: username/password only, marked experimental by MLflow, a permission race under parallel writers, no groups (one account per project in our setup). OIDC needs a third-party plugin or a proxy: Not tested | [w5-isolation.log](../evidence/mlflow-ray/w5-isolation.log), [w3-run-1.log](../evidence/mlflow-ray/w3-run-1.log) |
| Pipeline orchestration (Argo Workflows running Ray jobs) | Works: a resource step creates a RayJob and waits on its status; conditions, retries and a cron trigger behaved | [w3-run-1.log](../evidence/mlflow-ray/w3-run-1.log), [w3-scenarios.log](../evidence/mlflow-ray/w3-scenarios.log) |
| Ray Serve scale-to-zero | Partial: replicas and worker pods go to zero (202 s after the last request) and come back on the next request (110 s here). The head pod, 1 CPU / 2 GiB requested, runs for as long as the service exists | [w4-rayserve-llm.log](../evidence/mlflow-ray/w4-rayserve-llm.log) |
| Ray on Slurm (Snellius-style job) with MLflow tracking | Not tested: no Slurm in the timebox. The repository's `slinky/` lab could host this test | |
| Notebook environment (JupyterHub) integration | Works for login and spawn after the Cilium fix. Not integrated beyond a shared MLflow URL: no per-user credentials, no project namespaces, no Ray client set-up | [w1-first-login.log](../evidence/mlflow-ray/w1-first-login.log) |

## 9. Issues and workarounds

| # | Issue | Severity | Workaround | Upstream issue / docs | Status |
|---|---|---|---|---|---|
| 1 | Official MLflow image lacks PostgreSQL driver, S3 client and auth extras | Minor | Install at start, or build an image | | solved |
| 2 | MLflow 3.18 server OOM-killed at 2 GiB with default worker count | Minor | `--workers 2`, 3 GiB limit | | solved |
| 3 | Parallel writers creating the same experiment get 403 under basic auth | Minor | Create the experiment once before fanning out | | solved |
| 4 | Logging a transformers model fails importing `torchvision` | Minor | Pass `pip_requirements` | | solved |
| 5 | MLflow 3.18 refuses to save tree-based scikit-learn models until the type is declared trusted | Minor | `skops_trusted_types` | | solved |
| 6 | Ray's vLLM-based LLM serving needs a GPU | Minor | Hand-written wrapper on CPU | | accepted |
| 7 | No single sign-on in open-source MLflow; auth is basic and experimental | Major | Plugin or authenticating proxy (not tested) | | open |
| 8 | No pre-built images: packages installed on every job and every cold start (110 s cold start, 5.5 min first job) | Major | Build images in CI | | open |
| 9 | RayService worker pods never report Ready with the proxy on the head only | Minor | Cosmetic | | accepted |
| 10 | Ray Serve scale-to-zero keeps a head pod per service | Major | None found; share one cluster per project to limit it | | open |
| 11 | No pipeline engine | Major | Argo Workflows | Expected | solved |
| 12 | No project/tenancy object | Major | `tenant.sh` | Expected | solved (ours to maintain) |
| 13 | Project NetworkPolicy must admit the KubeRay operator | Minor | Rule in `tenant.sh` | | solved |
| 14 | JupyterHub chart NetworkPolicy blocks spawning on Cilium | Major | CiliumNetworkPolicy to `kube-apiserver` | Known issue | solved |
| 15 | JupyterHub: all users in one namespace, no quota, no per-user MLflow credentials | Major | Spawner customisation (not built) | | open |
| 16 | Ray dashboard and job API have no authentication | Major | NetworkPolicy per project (in place); do not expose | | accepted |
| 17 | No trigger on new data | Minor | Schedule + detect step, or add Argo Events | | accepted |
| 18 | No Prometheus, Grafana, usage, cost or energy reporting | Major | Add a monitoring stack | Expected in part | open |
| 19 | Lab only: Ray head on the 8 GiB control-plane node, with VM disks on a USB hard drive, stalled the cluster | Minor (not a candidate issue) | Keep Ray off the control-plane node; control-plane disk back on NVMe | | solved |
| 20 | Lab only: our SeaweedFS config lost project identities on restart and ran out of volumes | Minor (ours) | Identities in the filer only; higher volume limit | | solved |

## 10. Platform dependency (observed)

| Foundation | Works? | Notes |
|---|---|---|
| Kubernetes | Yes | Tested with KubeRay on RKE2 1.36 with Cilium |
| VMs (e.g. on OpenNebula) | Not tested | Supported by design (MLflow server and `ray up` on VMs). Argo, KubeRay and the JupyterHub chart would need replacements |
| Slurm / HPC | Not tested | Ray can run inside a Slurm allocation and log to a remote MLflow; this is the main thing to verify for Snellius |

## 11. Open questions and follow-ups

- SRAM: JupyterHub through its OIDC authenticator, and MLflow through a plugin or a proxy. Which claim maps to a project? [owner]
- GPU: Ray Train on multiple GPUs, Ray Serve with vLLM, GPU scheduling between projects (Kueue or similar). [owner]
- Ray on Slurm with MLflow tracking, using the `slinky/` lab. [owner]
- Is there an existing tenancy operator we would rather adopt than maintain `tenant.sh`? [owner]
- One shared Ray Serve cluster per project instead of one per service, to cap the always-on head pods. [owner]
- Would KubeRay's RayCronJob replace Argo for schedule-only retraining? [owner]
- MLflow evaluation and tracing for monitoring; a drift tool. [owner]
- Worker-node failure on replicated storage. [owner]

## Evidence

- Test kit and configs: `mlops/testkit/`, `mlops/mlflow-ray/` in the `instant-rke2-lab` repository (not committed yet)
- Logs: `mlops/evidence/mlflow-ray/`, `mlops/evidence/day2-*.log`, `mlops/evidence/00-upstream-versions.txt`
- Dashboards and screenshots: none taken
- Meeting notes or vendor contact: none

Related pages: MLOps principles; MLOps flow proposal: concept; MLOps platform comparison [ADD LINKS]

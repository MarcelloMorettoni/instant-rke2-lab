# POC findings: Kubeflow (upstream)

> Status: DRAFT · Last updated: 26 Nov 2026

| Field | Value |
|---|---|
| Candidate | Kubeflow (upstream) |
| Versions tested | Kubeflow manifests v1.11.0; component versions in section 2 |
| POC owner | [name] |
| Jira ticket | [NLAIF-xxx] |
| Timebox | [planned days] · Used: about half a day of hands-on lab time, shared with the MLflow + Ray candidate |
| Dates | 25 Nov 2026 – 26 Nov 2026 |
| Environment | RKE2 lab cluster on one desktop: 3 VMs, 16 vCPU / 40 GiB in total, no GPU, no SRAM; details in section 2 |
| Overall verdict | Viable with conditions |

Read this first:

- The lab has **no GPU and no SRAM**. W1, W2 and W4 were run CPU-sized with a 135M-parameter language model; the GPU, vLLM and SRAM parts are recorded as "Not tested".
- Evidence paths are relative to `mlops/` in the `instant-rke2-lab` repository. Nothing is committed yet, so there are no commit links.
- Timings marked (HDD) were taken while the worker VMs' disks sat on a USB hard drive (a lab storage problem, see section 9, issue 21). Both candidates were measured under the same conditions for W2 and W4; W1, W3 and W5 for Kubeflow ran on NVMe.

## 1. Summary

Verdict: Viable with conditions. Kubeflow covered more of the flow in one install than the alternative, and its project model (Profiles) is the strongest thing we tested. The price is a large, tightly coupled platform that only runs on Kubernetes, still needs MLflow for tracking, and has three tenancy defects in its defaults that we would have to close ourselves.

What worked well:

- Self-service start for a new user: first login, self-registered workspace and a running notebook in 68 s, without an administrator ([w1-first-login.log](../evidence/kubeflow/w1-first-login.log)).
- A project is one small YAML (Profile) and is usable in under a second, with RBAC, per-project object-store credentials and an isolated Pipelines API ([w5-profiles.log](../evidence/kubeflow/w5-profiles.log), [w5-isolation.log](../evidence/kubeflow/w5-isolation.log)).
- The whole training loop ran inside the platform: validate → train → evaluate → gate → register → deploy, then automatic retraining on new data ([w3-run-1.log](../evidence/kubeflow/w3-run-1.log), [w3-ct-loop.log](../evidence/kubeflow/w3-ct-loop.log)).
- KServe scale-to-zero and autoscaling worked out of the box: zero replicas 98 s after the last request, up to 3 replicas under load ([w4-kserve-llm.log](../evidence/kubeflow/w4-kserve-llm.log)).
- Katib ran a 4-trial search in 84 s with no extra setup ([katib-hpo.log](../evidence/kubeflow/katib-hpo.log)).

What did not work, or was harder than expected:

- A multi-node training job hangs in a default project because of the Istio sidecar; it needs an annotation to run (issue 8).
- A project with a CPU/memory quota cannot run pipelines at all until we add default limits (issue 12).
- Pods without a sidecar are reachable from other projects; Profiles create no NetworkPolicy (issue 11).
- The Model Registry is not part of the default install, is one shared instance, and answers any pod in the cluster without authentication (issue 14).
- Footprint: 56 pods, 69 CRDs, 88 images, about 15 GB of images on every worker node (section 2.3).

Hypotheses that changed: one. Stage 9 (Tenancy & identity) moves from Native to Partial, because the project model is built in but its default isolation has the three gaps above. Stage 8 (Monitoring) stays Partial, but note that nothing collects the metrics out of the box.

Conditions for adopting it:

- The foundation is Kubernetes (hard requirement).
- We add and maintain: MLflow for tracking, a NetworkPolicy and LimitRange per Profile, a registry per project or an authenticating proxy in front of it, Prometheus/Grafana, and a data-versioning tool.
- SRAM login through Dex is proven (not testable here).
- A team that can own Istio, Knative, Dex and three MySQL instances.

Recommended next step: keep Kubeflow as the candidate **if the foundation decision is Kubeflow-compatible Kubernetes and multi-tenant self-service is the top priority**. Before a pilot, retest on a cluster with GPUs and an SRAM test tenant, and try the three tenancy fixes as a Profile plugin or admission policy. See the [comparison](comparison.md) for how this weighs against MLflow + Ray.

## 2. Setup

### 2.1 Environment

| Item | Value |
|---|---|
| Foundation | Kubernetes: RKE2 v1.36.6+rke2r1 on 3 KVM/libvirt VMs (Ubuntu 24.04) on one desktop host |
| Nodes | 3: cp1 (control plane + etcd) 4 vCPU / 8 GiB; worker1 and worker2 6 vCPU / 16 GiB each |
| GPUs | None exposed to the cluster. Not tested: type, sharing mode |
| Storage | Storage class `local-path` (node-local, ReadWriteOnce). Object storage: SeaweedFS bundled with Kubeflow Pipelines. No shared file storage |
| Identity | Dex with local static users (the bundled default). SRAM not available |
| Network and access | Cilium 1.20.4 (kube-proxy replacement, VXLAN, set up for Istio: `cni.exclusive=false`, socket LB host-only). Access through `kubectl port-forward` to the Istio ingress gateway. No DNS, no TLS |
| Isolation from other POCs | Shared cluster with the MLflow + Ray candidate, in separate namespaces. Shared on purpose: the MLflow server (used here as the tracking add-on). Side effect: Kubeflow's Argo CRDs forced the other candidate onto the same Argo minor version |

### 2.2 Components and versions

| Component | Version | Installed how | Notes |
|---|---|---|---|
| Kubeflow manifests | v1.11.0 (tagged 15 Dec 2025) | `kustomize build example \| kubectl apply`, kustomize v5.7.1 | Upstream single-command install, unmodified |
| Kubeflow Pipelines | 2.15.0 | manifests | Upstream is at 2.18.2. Bundles Argo Workflows 3.7.3 (upstream 4.1.7), MySQL 8.4, SeaweedFS |
| Kubeflow Trainer | 2.1.0 | manifests | Upstream is at 2.4.0. Bundles JobSet |
| Katib | 0.19.0 | manifests | Own MySQL |
| KServe | 0.15.2 | manifests | Upstream is at 0.21.0. Serverless mode on Knative Serving 1.16.2 |
| Notebooks, Central Dashboard, Profiles + KFAM | 1.10.0 | manifests | |
| Model Registry | 0.3.4 | manifests, separate documented step | Not in the default install. Upstream is at 0.3.18. Own MySQL 8.3 |
| Istio / Knative / cert-manager / Dex / oauth2-proxy | 1.28.0 / 1.16.2 / 1.16.1 / 2.43.1 / 7.10.0 | manifests | Platform dependencies |
| Spark Operator | 2.4.0 | manifests | Installed by default, not used |
| MLflow (add-on) | 3.18.0 | plain manifests (`mlflow-ray/mlflow.yaml`) | With PostgreSQL 17 and an S3 store; basic auth on |

Version lag evidence: [00-upstream-versions.txt](../evidence/00-upstream-versions.txt).

### 2.3 Installation

| Measure | Value | Evidence |
|---|---|---|
| Effort to a working installation | About 25 min elapsed, of which the successful apply took 11 min (14 automatic retries). Model Registry: 1 more minute. Hands-on effort about 0.5 h | [01-install.log](../evidence/kubeflow/01-install.log), [03-model-registry-install.log](../evidence/kubeflow/03-model-registry-install.log) |
| Steps that were not in the official docs | 1 for the install (retry around the render); 3 more to make workloads run (listed below) | |
| Platform footprint at idle | 56 pods in 7 namespaces. Usage 0.32 CPU / 4.7 GiB; requests 3.3 CPU / 8.8 GiB. 69 CRDs, 4 PVCs. 88 images, about 15 GB per worker node | [04-idle-footprint.txt](../evidence/kubeflow/04-idle-footprint.txt), [02-pods.txt](../evidence/kubeflow/02-pods.txt), [05-node-disk-pipeline-pods.log](../evidence/kubeflow/05-node-disk-pipeline-pods.log) |
| External services it needs | All bundled: Istio, Knative Serving, cert-manager, Dex, oauth2-proxy, Argo Workflows, 3 MySQL instances (Pipelines, Katib, Model Registry), SeaweedFS. For tracking we added MLflow (PostgreSQL + S3) | |

Deviations from the documentation:

- The render fetches Argo Workflows and JobSet manifests from GitHub at build time. One fetch hit kustomize's 27 s timeout and one failed on DNS, so the install script retries the render. Not in the docs. (`kubeflow/install.sh`)
- The docs pin kustomize 5.7.1 and mean it: with the kustomize bundled in kubectl 1.36 (5.8.1) the default user Profile is rendered as a literal `$(profile-name)` and the apply never converges.
- Multi-node TrainJob: sidecar injection must be switched off on the job pods (issue 8).
- Profiles with a quota need a LimitRange added by hand (issue 12).
- KServe needs a ServiceAccount and an annotated Secret to read models from the Pipelines object store. This is documented by KServe, not by the Kubeflow install.

## 3. Reference workloads

Code and data: `mlops/testkit/` (shared), `mlops/kubeflow/workloads/` (Kubeflow side).

| # | Workload | Result | Time / effort | Notes | Evidence |
|---|---|---|---|---|---|
| W1 | GPU notebook session for a new user, from first login through SRAM | Works for a CPU notebook with a Dex local user. GPU and SRAM: Not tested | 68 s from first login to a running notebook (60 s of it image pull). Login + self-registration under 1 s | Self-registration is off by default; one documented setting turns it on | [w1-first-login.log](../evidence/kubeflow/w1-first-login.log) |
| W2 | Multi-node fine-tuning of a small open language model, tracked and registered | Workaround | 195 s wall for 2 nodes (85 s training) (HDD). Set-up: one TrainJob YAML and one script | Hangs with the default Istio sidecar. Tracked in MLflow (add-on), registered in Model Registry | [w2-attempt1-istio.log](../evidence/kubeflow/w2-attempt1-istio.log), [w2-trainjob.log](../evidence/kubeflow/w2-trainjob.log) |
| W3 | Training pipeline with automatic retrain on new data | Works | Pipeline: about 220 lines of Python. First run 331 s. New data to new registered version: 365 s on a 2-minute schedule | No data-event trigger: schedule plus a "detect new data" step | [w3-run-1.log](../evidence/kubeflow/w3-run-1.log), [w3-run-2-no-new-data.log](../evidence/kubeflow/w3-run-2-no-new-data.log), [w3-run-3-bad-data.log](../evidence/kubeflow/w3-run-3-bad-data.log), [w3-ct-loop.log](../evidence/kubeflow/w3-ct-loop.log) |
| W4 | vLLM endpoint for evaluation, with autoscaling and scale-to-zero | Works with the Hugging Face runtime on CPU. vLLM: Not tested (needs a GPU) | Cold start 23 s to 144 s (HDD; 42 s in the first run). Zero replicas 98 s after the last request. 3 replicas within about 20 s of load | OpenAI-style completions API. 404 requests in 180 s at 6 concurrent, p50 2.4 s, no errors | [w4-kserve-llm.log](../evidence/kubeflow/w4-kserve-llm.log), [run 1](../evidence/kubeflow/w4-kserve-llm-run1-overlapped.log) |
| W5 | Two projects side by side: isolation, quotas, access control | Works, with three isolation gaps | New project: one 10-line YAML, usable in under 1 s | RBAC, object store and Pipelines API are isolated. Network, registry and quota-vs-pipelines are not right by default | [w5-profiles.log](../evidence/kubeflow/w5-profiles.log), [w5-isolation.log](../evidence/kubeflow/w5-isolation.log) |

Notes per workload:

- W1: Logged in as a user that had no workspace. The dashboard offered self-registration (after setting `REGISTRATION_FLOW=true`), created the Profile, and the Jupyter web app spawned a notebook with a 5 GiB volume. Another user got 403 on that notebook. Surprises: a self-registered Profile has no quota; the notebook has no Pipelines token or MLflow settings until someone adds a PodDefault; idle notebooks are never culled by default (`ENABLE_CULLING=false`). The spawner form does list NVIDIA, AMD and Intel GPU options.
- W2: Kubeflow Trainer 2.1 TrainJob on the `torch-distributed` runtime, 2 nodes on 2 workers, fine-tuning SmolLM2-135M for 30 steps. First attempt hung for 10 minutes: the workers connect pod-to-pod on port 29500 in plaintext and the sidecar (strict mTLS) resets it. With `sidecar.istio.io/inject: "false"` it finished in 195 s. Other surprises: the stock runtime image is a 7 GB CUDA image, so we overrode it; the pod override API accepts affinity but not topology spread constraints. Loss curve logged to MLflow, model stored under the project's object-store prefix and registered with a link to the MLflow run.
- W3: Six lightweight Python components. The gate steps behave: no new data → rest skipped (70 s); malformed batch → stopped at validation (120 s); accuracy gate before register and deploy. The deploy step creates or updates a KServe InferenceService, and a prediction against it matched the expected labels. Surprises: the first run failed with "Access Denied" because each project's credentials only cover `private/<namespace>/…` (a good thing); environment variables cannot take pipeline parameters; a 6-step run starts at least 15 pods; finished step pods stay for 24 hours and each keeps its `pip install` layer on the node (about 4 GB for 40 pods).
- W4: The fine-tuned model from W2 served by KServe in serverless mode with `minReplicas: 0`. The Hugging Face runtime only uses vLLM on GPU and fell back to its transformers backend. Ready 163 s after the first apply (image pull). The cold-start spread comes from the lab disk, not from KServe.
- W5: Two Profiles with quotas. From project A: listing pods, secrets, notebooks or inference services in B is denied; B's object-store prefix is denied; B's pipeline runs are denied. But: a pod in B without a sidecar answers A (no NetworkPolicy exists); the shared Model Registry answers any pod; and a workflow in a quota'd project is rejected with "must specify limits.cpu for: init,wait". Each Istio sidecar also books 2 CPU / 1 GiB of limits against the quota.

## 4. Coverage per stage of the flow

| Stage | Hypothesis (comparison page) | Observed | Changed? | What we used | Evidence |
|---|---|---|---|---|---|
| 1 Data | Gap | Gap | No | Object-store prefix per project, our own fingerprint and validation code in a pipeline step. Pipelines records dataset artifacts per run, but nothing versions data. Closed in a follow-up test by adding lakeFS: see [the add-on page](data-versioning-and-catalog.md) | [w3-run-1.log](../evidence/kubeflow/w3-run-1.log), [kubeflow-w3-ct-loop.log](../evidence/lakefs/kubeflow-w3-ct-loop.log) |
| 2 Develop | Native | Native | No | Kubeflow Notebooks through the dashboard | [w1-first-login.log](../evidence/kubeflow/w1-first-login.log) |
| 3 Tracking | Partial | Partial | No | Pipeline run metrics inside Pipelines; MLflow for the training job and notebooks | [w2-trainjob.log](../evidence/kubeflow/w2-trainjob.log), [08-mlflow-from-notebook.log](../evidence/kubeflow/08-mlflow-from-notebook.log) |
| 4 Tune & train | Native | Native | No | Katib (grid search), Trainer v2 (2-node PyTorch). Multi-node needed the sidecar workaround | [katib-hpo.log](../evidence/kubeflow/katib-hpo.log), [w2-trainjob.log](../evidence/kubeflow/w2-trainjob.log) |
| 5 Pipelines | Native | Native | No | Kubeflow Pipelines v2, recurring runs | [w3-ct-loop.log](../evidence/kubeflow/w3-ct-loop.log) |
| 6 Registry | Partial | Partial | No | Model Registry 0.3.4: versions and free-form metadata work; no stages or aliases, no model-card object, no tenancy, separate install | [w3-run-1-registry-and-predict.log](../evidence/kubeflow/w3-run-1-registry-and-predict.log), [09-model-registry-ui.log](../evidence/kubeflow/09-model-registry-ui.log) |
| 7 Serving | Native | Native | No | KServe serverless with scale-to-zero | [w4-kserve-llm.log](../evidence/kubeflow/w4-kserve-llm.log) |
| 8 Monitoring | Partial | Partial | No | Metrics endpoints exist on 27 of 36 platform pods, but no Prometheus or Grafana is shipped and there is no drift detection | [day2-static-checks.log](../evidence/day2-static-checks.log) |
| 9 Tenancy & identity | Native | Partial | Yes | Profiles, Dex, oauth2-proxy, Istio policies. Built in and convenient, but three default isolation gaps (issues 11, 12, 14). SRAM not tested | [w5-isolation.log](../evidence/kubeflow/w5-isolation.log) |
| Count | 5 native, 3 partial, 1 gap | 4 native, 4 partial, 1 gap | | | |

## 5. Wrappers we had to build

| Wrapper | Type (light / complex) | Covers stage | Expected in hypothesis? | Build effort | Maintenance concern |
|---|---|---|---|---|---|
| MLflow for tracking, with a secret per project | light | 3 | Yes | 0.5 h for the server, minutes per project | No per-Profile wiring; a second login and a second permission model |
| "Detect new data" pipeline step + recurring run | light | 5 | No, new | 0.5 h | Polling; time to retrain is bounded by the schedule |
| Data validation and fingerprinting code | light | 1 | Yes (gap) | 0.5 h | It is our code, not a data-versioning tool |
| lakeFS for data versioning, with an adapter in the test kit (follow-up test) | light | 1 | Yes (gap) | 0.5 h, shared with MLflow + Ray | Open-source lakeFS has a single user: no isolation between projects |
| KServe storage ServiceAccount + Secret per project | light | 7 | No, new | 10 min | Must be created for every Profile |
| Sidecar opt-out on TrainJob pods | light | 4 | No, new | 15 min to diagnose | Every multi-node job needs it; it also removes those pods from mesh protection |
| LimitRange per Profile (not built, required) | light | 9 | No, new | est. 0.5 h | Profiles do not create it; needs a Profile plugin or a policy engine |
| NetworkPolicy per Profile (not built, required) | light | 9 | No, new | est. 1 h | Same |
| Model Registry per project, or an authenticating proxy (not built, required) | complex | 6, 9 | No, new | est. 1 day | One MySQL + server per project, or custom auth |
| Prometheus + Grafana (not built) | complex | 8 | Yes | not estimated | Separate stack to run |
| Dex static users for the lab | light | 9 | Yes (stand-in for SRAM) | 15 min | Replaced by an OIDC connector in reality; not tested |

## 6. Day-2 operations

| Check | Result | Effort | Evidence |
|---|---|---|---|
| Minor version upgrade (v1.10.x → v1.11.0) | Not tested: no earlier release was installed in the timebox. The upstream guidance is "a rough description for advanced users": re-render, re-apply, prune by hand, with manual steps in some releases | | [day2-static-checks.log](../evidence/day2-static-checks.log) |
| Backup and restore of metadata (runs, registry, pipelines) | Works for the two databases tested: Pipelines and Model Registry MySQL dumps restored into a scratch database with identical row counts. No bundled tool; four stores plus cluster state to cover | 15 min | [day2-backup-restore.log](../evidence/day2-backup-restore.log) |
| Recovery after a node failure | Partly tested, unplanned: the control-plane node stalled for about 25 minutes. About a dozen platform pods restarted (controllers that lost leader election, plus the Pipelines metadata services) and came back on their own; I restarted two to skip their back-off timer. A worker failure was not tested: with node-local storage it would measure the lab, not Kubeflow | | [07-control-plane-stall-recovery.log](../evidence/kubeflow/07-control-plane-stall-recovery.log) |
| Platform metrics and logs available | Workaround: endpoints exist, nothing scrapes them. Logs through `kubectl`; pipeline step logs are archived to the object store | | [day2-static-checks.log](../evidence/day2-static-checks.log) |
| Usage and cost per project visible | Fails: only quota counters per namespace | | [w5-isolation.log](../evidence/kubeflow/w5-isolation.log) |
| Energy per project visible | Fails: nothing shipped | | |
| Security: image scanning, policies, secrets handling | Mixed. Good: Pod Security Standards enforced on every namespace (restricted for platform, baseline for projects). Not good: default login, an empty MySQL root password and default object-store keys ship as-is; no image scanning or admission policy | | [day2-static-checks.log](../evidence/day2-static-checks.log) |

## 7. Evaluation criteria

The comparison page I was given has stage ratings but no per-criterion ratings, so the hypothesis column is empty.

| Criterion | Hypothesis (comparison page) | Observed | Evidence and reasoning |
|---|---|---|---|
| Capability coverage (stages 1–9) | Not on the page provided | Medium | 4 native, 4 partial, 1 gap. Needs MLflow, monitoring and data versioning added |
| Ease of use for researchers | Not on the page provided | Medium | One dashboard, self-service notebook in 68 s. But pipelines mean learning the KFP DSL, and Istio produces failures a researcher cannot diagnose (W2) |
| Openness and governance | Not on the page provided | Strong | Apache 2.0, CNCF, multi-vendor. Not assessed further in the POC |
| Modularity | Not on the page provided | Medium | Components can be installed one by one, but they are coupled through Istio, Dex and Profiles, and the bundle pins old versions of its parts |
| Multi-tenancy and identity | Not on the page provided | Medium | Best project model tested; three default isolation gaps; SRAM not tested |
| Upgrade and operational load | Not on the page provided | Weak | 56 pods, 69 CRDs, 88 images, 4 databases; render needs GitHub and an exact kustomize version; upgrade is a manual re-apply |
| Community and momentum | Not on the page provided | Medium | Latest platform release is 11 months old and bundles components 3 to 6 releases behind their upstreams |
| Platform independence | Not on the page provided | Weak | Kubernetes only |
| SURF ecosystem fit (SRAM, storage, Snellius) | Not on the page provided | Not tested | No SRAM or SURF storage in the lab. Dex supports OIDC connectors. No path to Snellius/Slurm |
| Sovereignty (runs fully on SURF infrastructure) | Not on the page provided | Strong | Everything ran on our own cluster. Images and the render come from public registries and GitHub, so an air-gapped install needs mirrors |
| Sustainability (scale-to-zero, usage metrics) | Not on the page provided | Medium | Serving scales to zero. Notebooks are never culled by default. Idle platform reserves 3.3 CPU / 8.8 GiB. No usage or energy metrics |
| FAIR-readiness (lineage, PIDs, export) | Not on the page provided | Medium | Pipelines records artifact lineage per run and the registry stores free-form metadata. No PIDs, no export tooling. Not tested in depth |
| Licence cost | Not on the page provided | Strong | None |

## 8. Candidate-specific checks

| Check | Result | Evidence |
|---|---|---|
| Model Registry maturity: versioning, metadata, model cards, UI | Versioning and custom metadata work (three versions with data fingerprint, accuracy and run id). No stages or aliases and no model-card object in the API. The UI is served and checks access per namespace, so a normal user sees nothing of a registry installed in `kubeflow`; the REST API behind it is open to every pod. Bundled 0.3.4 is 14 patch releases behind | [09-model-registry-ui.log](../evidence/kubeflow/09-model-registry-ui.log), [w3-ct-loop.log](../evidence/kubeflow/w3-ct-loop.log) |
| MLflow alongside Kubeflow: tracking from notebooks and pipelines | Works from a TrainJob and from a notebook. URL and credentials are passed by hand; nothing ties MLflow users to Profiles | [w2-trainjob.log](../evidence/kubeflow/w2-trainjob.log), [08-mlflow-from-notebook.log](../evidence/kubeflow/08-mlflow-from-notebook.log) |
| SRAM login via Dex (OIDC) and mapping to Profiles | Not tested: no SRAM tenant. Tested instead with Dex local users: login, self-registration and owner-only access work on the e-mail claim | [w1-first-login.log](../evidence/kubeflow/w1-first-login.log) |
| KServe scale-to-zero and vLLM runtime | Scale-to-zero works. vLLM runtime: Not tested (GPU only); CPU fallback served the same OpenAI-style API | [w4-kserve-llm.log](../evidence/kubeflow/w4-kserve-llm.log) |
| Upgrade path between Kubeflow releases | Not tested. Documented as a manual re-render and re-apply with per-release clean-up steps | [day2-static-checks.log](../evidence/day2-static-checks.log) |

## 9. Issues and workarounds

| # | Issue | Severity | Workaround | Upstream issue / docs | Status |
|---|---|---|---|---|---|
| 1 | Render with kubectl's bundled kustomize 5.8.1 leaves the default Profile unresolved; apply never converges | Minor | Use the pinned kustomize 5.7.1 | Manifests README, prerequisites | solved |
| 2 | Render is not hermetic: fetches from GitHub at build time, with a 27 s timeout | Minor | Retry; mirror for air-gapped | Not documented | accepted |
| 3 | Install burst exceeds the kubelet image-pull rate; pods crash-loop until dependencies are up (16 restarts) | Minor | Wait; it settles | | accepted |
| 4 | About 15 GB of images per worker node, 88 images | Minor | Size node disks for it | README resource table covers CPU and memory only | accepted |
| 5 | Finished pipeline pods are kept 24 h, each with its installed packages on the node | Minor | Bake images instead of installing at step start; shorten the TTL | | open |
| 6 | Environment variables on pipeline steps cannot take pipeline parameters | Minor | Use literals or component inputs | | accepted |
| 7 | No trigger on new data | Minor | Schedule + detect step, or add Argo Events | | accepted |
| 8 | Multi-node TrainJob hangs in a Profile namespace (Istio sidecar resets PyTorch rendezvous) | Major | `sidecar.istio.io/inject: "false"` on the job pods | Not in the install docs | solved |
| 9 | Stock `torch-distributed` runtime uses a 7 GB CUDA image | Minor | Override the image | | accepted |
| 10 | TrainJob pod overrides do not accept topology spread constraints | Minor | Pod anti-affinity | | accepted |
| 11 | No NetworkPolicy per Profile: pods without a sidecar are reachable from other projects | Major | Default-deny NetworkPolicy per Profile | | open |
| 12 | A Profile quota on CPU/memory blocks all pipeline pods (helper containers have no resources, no LimitRange) | Major | LimitRange per Profile | | open |
| 13 | Each Istio sidecar counts 2 CPU / 1 GiB of limits against the project quota | Minor | Size quotas for it or lower sidecar limits | | accepted |
| 14 | Model Registry: not installed by default, single shared instance, REST API open to any pod | Major | Registry per project, or a proxy with auth | Registry README describes per-namespace install | open |
| 15 | Self-registered Profiles get no quota | Minor | Profile plugin or policy | | open |
| 16 | No experiment tracker outside pipelines | Major | MLflow add-on | Expected | accepted |
| 17 | Default credentials ship unchanged (Dex user, empty MySQL root password, object-store keys) | Major | Rotate at install | README warns about the Dex password only | open |
| 18 | No Prometheus, Grafana, usage, cost or energy reporting | Major | Add a monitoring stack | Expected in part | open |
| 19 | Notebook idle culling is off by default | Minor | Set `ENABLE_CULLING` | | open |
| 20 | Bundled components lag their upstreams (KServe 0.15 vs 0.21, Pipelines 2.15 vs 2.18, Trainer 2.1 vs 2.4, Argo 3.7 vs 4.1) | Minor | Wait for the next platform release | | accepted |
| 21 | Lab only: host disk filled up, then the control plane stalled after VM disks were moved to a USB hard drive | Minor (not a Kubeflow issue) | Control-plane disk back on NVMe | | solved |

## 10. Platform dependency (observed)

| Foundation | Works? | Notes |
|---|---|---|
| Kubernetes | Yes | Tested on RKE2 1.36 with Cilium; the manifests target 1.34+ |
| VMs (e.g. on OpenNebula) | No | Not tested; every component is a Kubernetes controller. Only possible as Kubernetes on VMs, which is what this lab is |
| Slurm / HPC | No | Not tested; no integration exists in the release |

## 11. Open questions and follow-ups

- Does SRAM work as a Dex OIDC connector, and which claim becomes the Profile owner? [owner]
- GPU: notebook with a GPU, GPU sharing mode, KServe with the vLLM backend, multi-GPU TrainJob. [owner]
- Can the three tenancy fixes (NetworkPolicy, LimitRange, default quota) be delivered by a Profile plugin, or do we need a policy engine? [owner]
- Model Registry per project: footprint and effort, or wait for upstream tenancy? [owner]
- A real upgrade test: install v1.10.2, load it, upgrade to v1.11.0. [owner]
- Worker-node failure on replicated storage. [owner]
- Data versioning: lakeFS worked in a follow-up test, but its open-source edition has one user. One instance per project, the paid edition, or another tool? [owner]
- A data catalog (DataHub) has no Kubeflow source; is an emitter for Model Registry worth building? [owner]
- Would a trimmed install (no Spark operator, no Katib UI and so on) change the footprint enough to matter? [owner]

## Evidence

- Test kit and configs: `mlops/testkit/`, `mlops/kubeflow/` in the `instant-rke2-lab` repository (not committed yet)
- Logs: `mlops/evidence/kubeflow/`, `mlops/evidence/day2-*.log`, `mlops/evidence/00-upstream-versions.txt`
- Dashboards and screenshots: none taken
- Meeting notes or vendor contact: none

Related pages: MLOps principles; MLOps flow proposal: concept; MLOps platform comparison [ADD LINKS]

# POC comparison: Kubeflow (upstream) vs MLflow + Ray

> Status: DRAFT · Last updated: 26 Nov 2026
> Companion to the two findings pages: [Kubeflow](kubeflow.md) and [MLflow + Ray](mlflow-ray.md), and the add-on test [lakeFS + DataHub](data-versioning-and-catalog.md). Every number here comes from those pages and their evidence.

## Bottom line

Both candidates are **viable with conditions**, and they fail in opposite places.

- **Kubeflow** gives you the project model, notebooks, pipelines and serving in one install. You pay with a platform eight times larger, Kubernetes as the only possible foundation, MLflow still needed for tracking, and tenancy defaults that have to be fixed before real users arrive.
- **MLflow + Ray** gives you a small, modular core where training, tuning, tracking and registry simply work. You pay by adding notebooks and a pipeline engine and by building the project and identity layer yourself.

My recommendation: **take MLflow + Ray into the pilot as the primary candidate, and keep Kubeflow as the fallback.** Two of your own principles decide it: the foundation is not chosen yet, and Kubeflow rules out everything except Kubernetes; and "operational load matches the size of our team" is where Kubeflow scored worst. The recommendation flips if the first pilot check fails: if SRAM cannot be made to work for MLflow and JupyterHub with acceptable effort, Kubeflow's built-in project model becomes worth its weight, provided the foundation is Kubernetes.

What this lab could not tell you, for either candidate: anything about GPUs, vLLM, SRAM, Slurm, or behaviour beyond three small VMs. Those are the pilot's job.

## What was tested

One RKE2 1.36 cluster (3 VMs, 16 vCPU / 40 GiB, no GPU, no SRAM), both candidates installed side by side, the same five workloads with the same code, data and model (`mlops/testkit/`). W1, W2 and W4 were scaled down to CPU.

## Install and footprint

| | Kubeflow | MLflow + Ray |
|---|---|---|
| What gets installed | One 174,000-line rendered manifest | 4 independent pieces (MLflow manifests, 3 Helm charts) |
| Time for the install itself | 11 min apply (14 automatic retries) + 1 min registry | MLflow 1–2 min, KubeRay 25 s, Argo 8 s, JupyterHub 25 s |
| Hands-on effort to a working platform | about 0.5 h | about 2 h, half of it writing the tenancy script |
| Pods at idle | 56 | 7 |
| Idle requests | 3.3 CPU / 8.8 GiB | 0.75 CPU / 2.2 GiB (+ 1 CPU / 2 GiB per Ray Serve service) |
| CRDs | 69 | 12 |
| Databases to back up | 3 MySQL + object store | 1 PostgreSQL + object store + JupyterHub's |
| Images on disk | 88 images, about 15 GB per worker | Ray image 0.9 GB compressed per node plus a few small service images (not measured separately) |
| Version currency on the test date | Platform release 11 months old; parts 3–6 releases behind upstream | All latest (Argo held back by Kubeflow's CRDs on the shared cluster) |

## Workloads

| # | Workload | Kubeflow | MLflow + Ray |
|---|---|---|---|
| W1 | New user to running notebook (CPU; GPU and SRAM not tested) | Works. 68 s, self-service, own namespace | Workaround. 26 s, but needs JupyterHub + a Cilium policy; all users share one namespace |
| W2 | 2-node fine-tuning, tracked and registered | Workaround. 195 s wall; hangs until the Istio sidecar is disabled; tracking needs MLflow | Works. 353 s wall; installs packages on every node first |
| W3 | Pipeline with retrain on new data | Works. First run 331 s; new data → registered 365 s | Workaround (Argo added). First run 282 s; new data → registered 378 s, served 400 s |
| W4 | LLM endpoint, autoscaling, scale-to-zero (vLLM not tested) | Works. Cold start 23–144 s; fully to zero in 98 s; 3 replicas; 2.2 req/s | Workaround. Cold start 110 s; workers to zero in 202 s, head pod stays; 2 worker pods; 1.2 req/s |
| W5 | Two projects, isolation, quotas | Works with 3 gaps. One YAML per project | Workaround. Isolation held everywhere; one script run per project, script is ours |

Reading the timings:

- Training time itself was identical (85 s) and so was the loss curve. The wall-time difference in W2 is start-up overhead, mainly package installation, which a pre-built image removes on both sides.
- In W3 both spend most of "new data → new model" waiting for the 2-minute schedule. Neither has a data-event trigger.
- W4 is the one real performance gap, and its cause is known: KServe ships a ready runtime image, while our Ray worker installed PyTorch at every cold start.
- W1, W3 and W5 for Kubeflow ran on faster storage than everything for MLflow + Ray (see the note on the findings pages), so differences of a few tens of seconds there are not meaningful.

## Coverage per stage

| Stage | Kubeflow: hypothesis → observed | MLflow + Ray: hypothesis → observed |
|---|---|---|
| 1 Data | Gap → Gap | Partial → Partial |
| 2 Develop | Native → Native | Gap → Gap (JupyterHub added) |
| 3 Tracking | Partial → Partial (MLflow added) | Native → Native |
| 4 Tune & train | Native → Native | Native → Native |
| 5 Pipelines | Native → Native | Gap → Gap (Argo added) |
| 6 Registry | Partial → Partial | Native → Native |
| 7 Serving | Native → Native | Native → Native (scale-to-zero only partial) |
| 8 Monitoring | Partial → Partial | Partial → Partial |
| 9 Tenancy & identity | Native → **Partial** | Partial → Partial (low end) |
| Count | 5 / 3 / 1 → 4 / 4 / 1 | 4 / 3 / 2 → 4 / 3 / 2 |

The comparison page's hypotheses held up almost entirely. The one change is Kubeflow's tenancy: built in, but not safe as installed.

## Follow-up: closing the Data stage with lakeFS and DataHub

Tested after the main POC; details and evidence on [the add-on page](data-versioning-and-catalog.md).

| | Kubeflow | MLflow + Ray |
|---|---|---|
| W3 retraining from a lakeFS commit | Works. New commit → new version in 331 s | Works. New commit → new version in 249 s, served in 271 s |
| Exact dataset of an older model readable | Yes | Yes |
| DataHub sees models and runs | No source for Kubeflow; needs our own emitter (not tested) | Yes, through the MLflow source |
| Lineage model → dataset in the catalog | Not tested | Works after logging the dataset as an MLflow input |

- lakeFS removes Stage 1 as a difference between the candidates. Its cost is small (2 pods); its condition is that the open-source edition has a single user, so it does not isolate projects.
- DataHub favours MLflow + Ray, but it is a platform in itself (6 pods, about 3.7 GiB at idle) and optional.
- The stage ratings above are unchanged: they describe the candidates as shipped.

## Evaluation criteria

| Criterion | Kubeflow | MLflow + Ray | What decides it |
|---|---|---|---|
| Capability coverage | Medium | Medium | Kubeflow lacks tracking; MLflow + Ray lacks notebooks, pipelines |
| Ease of use for researchers | Medium | Medium | One dashboard vs plain Python; Istio surprises vs three logins |
| Openness and governance | Strong | Strong | Apache 2.0 on both sides |
| Modularity | Medium | Strong | Coupled bundle vs four independent installs |
| Multi-tenancy and identity | Medium | Weak | Profiles with gaps vs everything self-built, no single sign-on |
| Upgrade and operational load | Weak | Medium | 56 pods and a manual re-apply vs 7 pods and Helm, plus our own glue |
| Community and momentum | Medium | Strong | Release age and lag of bundled parts |
| Platform independence | Weak | Medium | Kubernetes only vs designed for more, but only Kubernetes tested |
| SURF ecosystem fit | Not tested | Not tested | No SRAM, SURF storage or Snellius in the lab |
| Sovereignty | Strong | Strong | Both ran entirely on our own cluster |
| Sustainability | Medium | Medium | True scale-to-zero vs small idle footprint; neither reports usage or energy |
| FAIR-readiness | Medium | Medium | Lineage on both sides; no PIDs on either |
| Licence cost | Strong | Strong | None |

## What we would have to build and maintain

| | Kubeflow | MLflow + Ray |
|---|---|---|
| Light wrappers | MLflow add-on; detect-new-data step; KServe storage secret per project; sidecar opt-out for training jobs; LimitRange and NetworkPolicy per project | JupyterHub + Cilium policy; detect-new-data step; deploy and verify steps; MLflow image and auth config; CPU serving wrapper |
| Complex wrappers | Registry per project or an auth proxy; monitoring stack | Pipeline definitions on Argo; the tenancy script; single sign-on across three tools; monitoring stack |
| Largest open item | Tenancy defaults (3 Major issues) | Identity (no SSO in MLflow, hub users not tied to projects) |
| Issues found: Major / Minor | 7 / 13 (+1 lab-only) | 9 / 9 (+2 lab-only) |

## Major findings, side by side

Kubeflow:

1. Multi-node training jobs hang in a default project until the Istio sidecar is switched off on them.
2. A project with a CPU/memory quota cannot run pipelines until default limits are added.
3. Projects have no NetworkPolicy; pods without a sidecar are reachable from other projects.
4. The Model Registry is a separate install, one shared instance, with an open in-cluster API.
5. Default credentials ship unchanged (login, MySQL root, object-store keys).
6. Tracking outside pipelines needs MLflow, which is not wired to projects.
7. No monitoring stack, usage, cost or energy reporting.

MLflow + Ray:

1. No project object: the tenancy layer is our own script.
2. No single sign-on in open-source MLflow; its auth is basic and experimental.
3. JupyterHub users share one namespace and are not linked to projects or MLflow accounts.
4. Ray's dashboard and job API have no authentication; only the network policy protects them.
5. Ray Serve "scale to zero" keeps a head pod per service.
6. No pre-built images: packages installed on every job and cold start.
7. No pipeline engine (Argo added) and JupyterHub blocked by its own network policy on Cilium.
8. No monitoring stack, usage, cost or energy reporting.

## What decides between them

| If this is true | Then |
|---|---|
| The foundation will be Kubernetes, and many research groups need self-service projects soon | Kubeflow's Profiles save the most work, once the three tenancy fixes are in |
| The foundation is still open, or must include VMs or Snellius | Only MLflow + Ray keeps that door open |
| The platform team is small | MLflow + Ray: an eighth of the pods, one database, Helm upgrades |
| SRAM single sign-on across every tool is a hard requirement from day one | Kubeflow has one login path to prove (Dex); MLflow + Ray has three |
| Researchers mostly write Python and submit jobs | MLflow + Ray fits how they already work |
| Researchers want a portal with notebooks, pipelines and endpoints in one place | Kubeflow |

A hybrid is also possible and worth a look in the pilot: Kubeflow lists a KubeRay integration as experimental, and we already ran MLflow next to Kubeflow without trouble. That would mean Kubeflow for projects, notebooks and KServe, with MLflow and Ray for tracking and compute. It inherits Kubeflow's footprint and Kubernetes-only constraint.

## Proposed pilot checks, in order

1. SRAM login: JupyterHub (OIDC) and MLflow (plugin or proxy); for the fallback, Dex → Profiles.
2. GPUs: multi-GPU Ray Train, Ray Serve with vLLM and its cold start with a pre-built image; KServe with the vLLM backend for comparison.
3. Ray on Slurm with MLflow tracking (the repository's `slinky/` lab can host it).
4. A tenancy layer we are willing to own: harden `tenant.sh` or adopt an existing operator.
5. Data versioning with project isolation: one lakeFS per project, its paid edition, or an alternative.
6. Monitoring, usage and energy per project (Prometheus, OpenCost, Kepler or similar): needed for either candidate.
7. For Kubeflow, if it stays in play: a real v1.10 → v1.11 upgrade and the three tenancy fixes as a Profile plugin or policy.

## Limits of this POC

- CPU only, one small cluster, one operator, about half a day. Effort figures are one person's elapsed time, not a team estimate.
- ClearML, the third candidate on the comparison page, was not tested.
- The hypothesis column for the 13 criteria is empty on both pages because the comparison page I was given only carries stage ratings.
- Part of the session was lost to lab storage problems that have nothing to do with either candidate; the affected timings are marked on the findings pages.
- Community, governance and licence ratings rest on public facts, not on anything the lab exercised.

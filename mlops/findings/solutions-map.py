#!/usr/bin/env python3
"""Generates solutions-map.excalidraw: MLOps flow components x solutions.

  solutions-map.py                 write solutions-map.excalidraw next to this file
  solutions-map.py <board-url>     also PUT the scene to an excalidraw-persist board,
                                   e.g. http://localhost:4000/api/boards/<id>/elements

Solid card = exercised in the lab. Dashed card = named in the findings, not tested.
"""
import json
import pathlib
import sys
import textwrap
import urllib.request

T, N = True, False  # tested / not tested

KF, ML, RAY, OTHER = "kubeflow", "mlflow", "ray", "other"
FAMILY = {
    KF: ("Kubeflow 1.11", "One install: notebooks, pipelines, training, registry, serving", "#1971c2", "#d0ebff"),
    ML: ("MLflow 3.18", "Tracking server and registry; one service, one database", "#e8590c", "#ffe8cc"),
    RAY: ("Ray 2.60 on KubeRay", "KubeRay starts Ray clusters, jobs and services on demand", "#6741d9", "#e5dbff"),
    OTHER: ("Stand-alone tools", "Installed separately; usable with either candidate", "#495057", "#f1f3f5"),
}
PHASES = [
    ("1 Experiment", "researcher-driven", "#e7f5ff"),
    ("2 Automate", "CI / CD / CT", "#fff0f6"),
    ("3 Deploy & operate", "production", "#ebfbee"),
]

# (phase, component, need, {family: [(name, purpose, tested)]})
ROWS = [
    (0, "① Data: version & validate", "Versioned datasets, schema and quality checks", {
        ML: [("MLflow dataset tracking", "Records which dataset a run used: name, digest and source. Does not store or version data.", T)],
        RAY: [("Ray Data", "Loads and preprocesses data in parallel for training. No versioning.", N)],
        OTHER: [
            ("lakeFS", "Versions the data: commits, branches and tags on top of the object store. A model points to the exact commit it was trained on.", T),
            ("DataHub", "Catalog: find datasets, owners and lineage from a model back to its dataset. Does not version data.", T),
            ("Object store (SeaweedFS, S3)", "Holds the actual files. lakeFS, MLflow and Kubeflow Pipelines all store on it.", T),
            ("Great Expectations, Pandera", "Schema and quality checks. In the lab this was our own pipeline step.", N),
        ],
    }),
    (0, "② Develop", "Notebooks and IDEs on GPUs, reproducible images", {
        KF: [("Kubeflow Notebooks", "Jupyter, VS Code or RStudio per user, started from the dashboard in the project's namespace.", T)],
        OTHER: [("JupyterHub", "Notebook servers for the MLflow + Ray stack. All users share one namespace.", T)],
    }),
    (0, "③ Track experiments", "Parameters, metrics, artifacts and lineage per run", {
        KF: [("Pipelines run metadata", "Metrics and artifacts of pipeline runs only. Training jobs and notebooks need MLflow.", T)],
        ML: [("MLflow Tracking", "Parameters, metrics and artifacts per run, with a UI to compare runs. Used with both candidates.", T)],
    }),
    (0, "④ Tune & train at scale", "Hyperparameter search, distributed multi-GPU training", {
        KF: [("Katib", "Hyperparameter search: runs each trial as a Kubernetes job.", T),
             ("Kubeflow Trainer", "Distributed training jobs (PyTorch) across nodes.", T)],
        RAY: [("Ray Tune", "Hyperparameter search inside a Ray cluster.", T),
              ("Ray Train", "Distributed training across Ray workers.", T)],
    }),
    (1, "Commit to Git", "Code, pipeline definition and config as code", {
        OTHER: [("Git forge (GitHub, GitLab)", "Holds code, pipeline definitions and config. The source for CI and CD.", N)],
    }),
    (1, "CI: test & build", "Unit tests, data checks, container image", {
        OTHER: [("CI runner (GitHub Actions, GitLab CI)", "Runs tests and data checks, builds the container image.", N),
                ("Image registry (Harbor)", "Stores built images. Pre-built images remove the package installs that slowed jobs and cold starts in the lab.", N)],
    }),
    (1, "⑤ Training pipeline (CT)", "Validate data, train, evaluate, validate model", {
        KF: [("Kubeflow Pipelines", "Pipelines written in Python: validate, train, evaluate, register. Runs on Argo Workflows.", T)],
        OTHER: [("Argo Workflows", "Pipeline engine added to the MLflow + Ray stack: steps in YAML that start Ray jobs. Also the engine under Kubeflow Pipelines.", T)],
    }),
    (1, "⑥ Model registry", "Versioned, approved models with model cards", {
        KF: [("Kubeflow Model Registry", "Model versions with free-form metadata. Separate install, one shared instance, no aliases.", T)],
        ML: [("MLflow Model Registry", "Model versions, tags and aliases, linked to the run that produced them.", T)],
    }),
    (2, "CD: deploy", "GitOps: staging, canary, production", {
        OTHER: [("Argo CD, Flux", "Roll out from Git through staging, canary and production. In the lab a pipeline step deployed the model.", N)],
    }),
    (2, "⑦ Serve", "Online, batch and LLM endpoints with autoscaling", {
        KF: [("KServe", "Model endpoints with autoscaling and full scale-to-zero. Needs Knative and Istio.", T)],
        RAY: [("Ray Serve", "Endpoints as Python deployments with autoscaling. A head pod stays up at zero.", T)],
        OTHER: [("vLLM", "LLM inference runtime that both KServe and Ray Serve can use. Needs a GPU.", N)],
    }),
    (2, "⑧ Monitor", "Performance, drift, data quality, cost and energy", {
        ML: [("MLflow evaluation and tracing", "Model quality scores and LLM traces.", N)],
        RAY: [("Ray dashboard and metrics", "Cluster and job view plus a Prometheus endpoint. Nothing collects it yet.", T)],
        OTHER: [("Prometheus + Grafana", "Collects and shows platform and endpoint metrics. Needed for either candidate.", N),
                ("Evidently or similar", "Drift and data-quality reports on served models.", N),
                ("OpenCost, Kepler", "Cost and energy per project.", N)],
    }),
    (2, "Retrain trigger", "Drift or new data starts the training pipeline again", {
        KF: [("Pipelines recurring run", "Starts the pipeline on a schedule; a detect step skips it when there is no new data.", T)],
        OTHER: [("Argo CronWorkflow", "The same schedule-plus-detect pattern for the MLflow + Ray stack.", T),
                ("Argo Events", "Would start the pipeline on a data event instead of a schedule.", N)],
    }),
]

# ---- geometry -------------------------------------------------------------
CW, PAD, GAP = 300, 14, 12           # card width, cell padding, gap between cards
COMP_W = 270
COLS = [(KF, 1), (ML, 1), (RAY, 1), (OTHER, 2)]   # family, cards per line
COL_GAP = 26
TITLE, BODY, LH = 18, 14, 1.25
WRAP_TITLE, WRAP_BODY = 30, 40

els, seq = [], [0]
B62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def base(kind, x, y, w, h, **kw):
    n = seq[0]
    seq[0] += 1
    e = dict(id=f"sm-{n:04d}", type=kind, x=x, y=y, width=w, height=h, angle=0,
             strokeColor="#1e1e1e", backgroundColor="transparent", fillStyle="solid",
             strokeWidth=1, strokeStyle="solid", roughness=1, opacity=100, groupIds=[],
             frameId=None, index="b" + B62[n // 62] + B62[n % 62], roundness=None,
             seed=1000 + n, version=1, versionNonce=5000 + n, isDeleted=False,
             boundElements=[], updated=1795000000000, link=None, locked=False)
    e.update(kw)
    els.append(e)
    return e


def rect(x, y, w, h, **kw):
    kw.setdefault("roundness", {"type": 3})
    return base("rectangle", x, y, w, h, **kw)


def text(x, y, s, size=BODY, color="#1e1e1e", wrap=None, family=2, **kw):
    if wrap:
        s = "\n".join(textwrap.wrap(s, wrap))
    lines = s.split("\n")
    h = len(lines) * size * LH
    w = max(len(l) for l in lines) * size * 0.55
    base("text", x, y, w, h, strokeColor=color, text=s, originalText=s, fontSize=size,
         fontFamily=family, textAlign="left", verticalAlign="top", containerId=None,
         lineHeight=LH, autoResize=True, **kw)
    return h


def card_height(name, purpose):
    t = len(textwrap.wrap(name, WRAP_TITLE))
    b = len(textwrap.wrap(purpose, WRAP_BODY))
    return 10 + t * TITLE * LH + 6 + b * BODY * LH + 10


def cell_height(cards, per_line):
    if not cards:
        return 40
    h = 0
    for i in range(0, len(cards), per_line):
        h += max(card_height(c[0], c[1]) for c in cards[i:i + per_line]) + GAP
    return h - GAP


def draw_cards(x, y, cards, per_line, fam):
    _, _, stroke, bg = FAMILY[fam]
    for i in range(0, len(cards), per_line):
        line = cards[i:i + per_line]
        lh = max(card_height(c[0], c[1]) for c in line)
        for j, (name, purpose, tested) in enumerate(line):
            cx = x + j * (CW + GAP)
            rect(cx, y, CW, lh, strokeColor=stroke, backgroundColor=bg if tested else "#ffffff",
                 strokeStyle="solid" if tested else "dashed", strokeWidth=2 if tested else 1)
            th = text(cx + 10, y + 10, name, TITLE, wrap=WRAP_TITLE)
            text(cx + 10, y + 10 + th + 6, purpose, BODY, "#343a40", wrap=WRAP_BODY)
        y += lh + GAP


# column x positions
col_x, x = {}, COMP_W + 60
for fam, per in COLS:
    col_x[fam] = x
    x += per * CW + (per - 1) * GAP + 2 * PAD + COL_GAP
RIGHT = x - COL_GAP
K8S_X = COMP_W + 30
HEAD_H, K8S_HEAD = 78, 92
TOP = 150                                   # y of the Kubernetes box
BODY_TOP = TOP + K8S_HEAD + HEAD_H + 16     # first row

# title
text(0, 0, "MLOps flow: solutions per component", 32, family=5)
text(0, 50, "One row per box of the flow. A solution that covers several components is one bigger box holding its parts. "
            "Tested on the RKE2 lab, 25–26 Nov 2026.", 16, "#495057")
# legend
lx = 0
for label, style, bg in (("Exercised in the lab", "solid", "#f1f3f5"), ("Named in the findings, not tested", "dashed", "#ffffff")):
    rect(lx, 88, 34, 22, strokeStyle=style, backgroundColor=bg, strokeColor="#495057", strokeWidth=2 if style == "solid" else 1)
    text(lx + 44, 91, label, 14, "#495057")
    lx += 250
text(lx + 60, 91, "–   no component for this step", 14, "#868e96")

# row layout
y, row_geo, phase_span = BODY_TOP, [], {}
for i, (ph, comp, need, cells) in enumerate(ROWS):
    if i == 0 or ROWS[i - 1][0] != ph:
        y += 46 if i else 0                 # room for the phase label
        phase_span[ph] = [y, y]
    h = max(cell_height(cells.get(f, []), per) for f, per in COLS)
    h = max(h, 30 + len(textwrap.wrap(need, 32)) * BODY * LH + 30) + 2 * PAD
    row_geo.append((y, h))
    y += h
    phase_span[ph][1] = y
BOTTOM = y

# phase bands (behind everything else)
for ph, (y0, y1) in phase_span.items():
    name, sub, bg = PHASES[ph]
    rect(-20, y0 - 40, RIGHT + PAD + 40, y1 - y0 + 52, backgroundColor=bg, strokeColor="#ced4da", strokeStyle="dashed")
    text(0, y0 - 32, name, 20, "#5f3dc4")
    text(len(name) * 10.5 + 14, y0 - 27, sub, 14, "#868e96")

# Kubernetes box around every solution column
rect(K8S_X, TOP, RIGHT + PAD - K8S_X, BOTTOM + 20 - TOP, strokeWidth=4, strokeColor="#1e1e1e")
text(K8S_X + 20, TOP + 14, "Kubernetes (RKE2 + Cilium)", 24, family=5)
text(K8S_X + 20, TOP + 50, "Every box inside runs on it. It gives all of them: scheduling and autoscaling of pods, a namespace and quota per project, "
                           "network policy, storage volumes and scheduled jobs.", 14, "#343a40", wrap=150)
text(K8S_X + 1010, TOP + 20, "MLflow and Ray are designed to run outside Kubernetes too\n(VMs, Slurm): not tested. Kubeflow runs only on Kubernetes.", 14, "#868e96")

# family boxes: one tall box per product, header on top
for fam, per in COLS:
    name, sub, stroke, bg = FAMILY[fam]
    w = per * CW + (per - 1) * GAP + 2 * PAD
    x0, y0 = col_x[fam], TOP + K8S_HEAD
    if fam != OTHER:
        rect(x0, y0, w, BOTTOM + 6 - y0, strokeColor=stroke, strokeWidth=3)
    rect(x0, y0, w, HEAD_H, strokeColor=stroke, backgroundColor=bg, strokeWidth=3 if fam != OTHER else 1)
    text(x0 + PAD, y0 + 10, name, 22, stroke, family=5)
    text(x0 + PAD, y0 + 42, sub, 13, "#343a40", wrap=44 if per == 1 else 90)

# rows
for (ph, comp, need, cells), (ry, rh) in zip(ROWS, row_geo):
    rect(0, ry + 6, COMP_W, rh - 12, strokeWidth=2, backgroundColor="#ffffff")
    th = text(12, ry + 18, comp, 18, wrap=26)
    text(12, ry + 18 + th + 6, need, BODY, "#343a40", wrap=32)
    for fam, per in COLS:
        cards = cells.get(fam, [])
        if cards:
            draw_cards(col_x[fam] + PAD, ry + PAD, cards, per, fam)
        else:
            text(col_x[fam] + PAD + 10, ry + PAD + 4, "–", 20, "#adb5bd")

scene = {"type": "excalidraw", "version": 2, "source": "mlops/findings/solutions-map.py",
         "elements": els, "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None}, "files": {}}
out = pathlib.Path(__file__).with_suffix(".excalidraw")
out.write_text(json.dumps(scene, indent=1, ensure_ascii=False))
print(f"{out}: {len(els)} elements, {RIGHT + PAD:.0f} x {BOTTOM:.0f}")

if len(sys.argv) > 1:
    req = urllib.request.Request(sys.argv[1], method="PUT", headers={"Content-Type": "application/json"},
                                 data=json.dumps({"elements": els, "files": {}}).encode())
    print(urllib.request.urlopen(req, timeout=30).read().decode())

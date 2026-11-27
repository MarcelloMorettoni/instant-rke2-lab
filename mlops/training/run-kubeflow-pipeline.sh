#!/usr/bin/env bash
# Lesson 5 from start to finish in one script: data -> code -> CI -> pipeline -> models -> endpoints.
#
#   mlops/training/run-kubeflow-pipeline.sh                 trains on the data branches main and experiment
#   mlops/training/run-kubeflow-pipeline.sh main            only main
#   mlops/training/run-kubeflow-pipeline.sh main experiment sample-300
#
# What it does, each step printed as it happens:
#   1. Data     lakeFS repository kf-my-data with one commit per branch (created only if missing)
#   2. Code     data-branches.txt in the Gitea repository lab/my-model-kubeflow lists the branches;
#               a change is committed and pushed, otherwise the CI workflow is started by hand
#   3. CI       waits for the Gitea job that compiles and uploads the pipeline and starts one run per branch
#   4. Pipeline follows every run in Kubeflow, step by step:
#               detect-change -> validate-data -> train-model -> evaluate-model -> quality-gate -> register-model -> deploy-model
#   5. Models   what the Model Registry recorded for each model (data branch, data commit, git commit)
#   6. Serving  waits for each KServe endpoint and sends it five test readings
#   7. Tests    a few checks per endpoint (kubeflow/test_endpoint.py): ready, output contract, accuracy on
#               fresh readings, same answer twice, bad input refused, latency, serves the newest version
#
# It is safe to run again: existing data is left alone and every pass trains a new version of each model.
# Needs the port-forwards (mlops/training/lab.sh up). Nothing is installed on this machine.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck disable=SC1091
source "${MLOPS_ROOT}/training/env.sh" >/dev/null
# shellcheck disable=SC1090
source "${LAB_ROOT}/.state/mlops-gitea.env"

REPO=kf-my-data MODEL=my-model CODE=lab/my-model-kubeflow GITEA=http://127.0.0.1:3000
BRANCHES=("$@"); [[ ${#BRANCHES[@]} -gt 0 ]] || BRANCHES=(main experiment)
step() { printf '\n\033[1;34m[%s/7] %s\033[0m\n' "$1" "$2"; }
die()  { printf '\033[1;31mERROR %s\033[0m\n' "$*" >&2; exit 1; }
api()  { curl -sf -m 20 -u "${GITEA_USER}:${GITEA_PASSWORD}" -H 'Content-Type: application/json' "$@"; }
model_of() { [[ "$1" == main ]] && echo "${MODEL}" || echo "${MODEL}-$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"; }

curl -sf -m 5 "${GITEA}/api/healthz" >/dev/null || die "Gitea does not answer on ${GITEA}: run mlops/training/lab.sh up"

# ---------------------------------------------------------------------------------------------
step 1 "Data in lakeFS: repository ${REPO}, branches ${BRANCHES[*]}"
repos="$(lakectl repo list 2>/dev/null || true)"
if ! grep -q "^${REPO}[[:space:]]" <<<"${repos}"; then
  lakectl repo create "lakefs://${REPO}" "s3://lakefs/${REPO}-$(date +%s)" | tail -1
  lakectl fs upload -s - "lakefs://${REPO}/main/datasets/w3/batch-001.csv" < "${MLOPS_ROOT}/training/data/batch-001.csv" >/dev/null
  lakectl commit "lakefs://${REPO}/main" -m "Batch 1" | grep -E '^(ID|Message)'
fi
for b in "${BRANCHES[@]}"; do
  have="$(lakectl branch list "lakefs://${REPO}")"
  if ! grep -q "^${b}[[:space:]]" <<<"${have}"; then
    # A new branch starts from main and gets a different cut of the data, so its model differs.
    lakectl branch create "lakefs://${REPO}/${b}" -s "lakefs://${REPO}/main" >/dev/null
    lakectl fs cat "lakefs://${REPO}/main/datasets/w3/batch-001.csv" | python3 -c '
import csv, sys
rows = list(csv.DictReader(sys.stdin))
out = csv.DictWriter(sys.stdout, rows[0].keys()); out.writeheader()
out.writerows(r for r in rows if abs(float(r["temperature"])) < 1)' \
      | lakectl fs upload -s - "lakefs://${REPO}/${b}/datasets/w3/batch-001.csv" >/dev/null
    lakectl commit "lakefs://${REPO}/${b}" -m "Keep readings within 1 standard deviation" >/dev/null
    echo "created branch ${b} with filtered data"
  fi
done
lakectl branch list "lakefs://${REPO}" | awk 'NF {printf "  branch %-14s at commit %s\n", $1, substr($2,1,12)}'

# ---------------------------------------------------------------------------------------------
step 2 "Code in Gitea: ${CODE}, data-branches.txt = ${BRANCHES[*]}"
work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader   # the password travels in a header, not in the URL
GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s:%s' "${GITEA_USER}" "${GITEA_PASSWORD}" | base64 -w0)"
export GIT_CONFIG_VALUE_0
git clone -q "${GITEA}/${CODE}.git" "${work}/code"
last_ci="$(api "${GITEA}/api/v1/repos/${CODE}/actions/tasks?limit=1" | python3 -c 'import sys,json; r=json.load(sys.stdin).get("workflow_runs") or [{"id":0}]; print(r[0]["id"])')"
{ grep '^#' "${work}/code/data-branches.txt" 2>/dev/null || true; printf '%s\n' "${BRANCHES[@]}"; } > "${work}/branches.new"
if cmp -s "${work}/branches.new" "${work}/code/data-branches.txt"; then
  echo "data-branches.txt already lists these branches: starting the CI workflow by hand"
  api -X POST "${GITEA}/api/v1/repos/${CODE}/actions/workflows/train.yaml/dispatches" -d '{"ref":"main"}' >/dev/null
else
  cp "${work}/branches.new" "${work}/code/data-branches.txt"
  git -C "${work}/code" -c user.name="${GITEA_USER}" -c user.email="${GITEA_USER}@lab.invalid" commit -qam "Train on the data branches: ${BRANCHES[*]}"
  git -C "${work}/code" push -q origin main 2>&1 | grep -v '^remote:' || true
  echo "pushed: $(git -C "${work}/code" log -1 --oneline)"
fi
sha="$(git -C "${work}/code" rev-parse HEAD)"; short="${sha:0:8}"

# ---------------------------------------------------------------------------------------------
step 3 "CI in Gitea: compile, upload pipeline version commit-${short}, start the runs"
deadline=$(( $(date +%s) + 420 )); status=""
while [[ "${status}" != success ]]; do
  (( $(date +%s) < deadline )) || die "CI job not finished after 7 minutes: ${GITEA}/${CODE}/actions"
  sleep 5
  status="$(api "${GITEA}/api/v1/repos/${CODE}/actions/tasks?limit=5" | python3 -c "
import sys, json
runs = [r for r in json.load(sys.stdin).get('workflow_runs') or [] if r['id'] > ${last_ci}]
print(runs[-1]['status'] if runs else 'waiting')")"
  [[ "${status}" == failure ]] && die "CI job failed: open ${GITEA}/${CODE}/actions"
done
echo "CI job: success"

# ---------------------------------------------------------------------------------------------
step 4 "Pipeline in Kubeflow: one run per data branch (http://localhost:8080 -> Runs)"
runs=(); for b in "${BRANCHES[@]}"; do m="$(model_of "${b}")"; runs+=("commit-${short}${m#"${MODEL}"}"); done
kf-kit - "${runs[@]}" <<'PY'
import contextlib, io, sys, time, kfp
STEPS = ["detect-change", "validate-data", "train-model", "evaluate-model", "quality-gate", "register-model", "deploy-model"]
client = kfp.Client()
namespace = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
with contextlib.redirect_stdout(io.StringIO()):  # the SDK prints a console link here
    experiment = client.create_experiment("my-model", namespace=namespace)
newest = {}
for r in client.list_runs(experiment_id=experiment.experiment_id, page_size=50, sort_by="created_at desc").runs or []:
    newest.setdefault(r.display_name, r.run_id)
missing = [n for n in sys.argv[1:] if n not in newest]
if missing:
    sys.exit(f"runs not found in Kubeflow: {missing}")
seen, t0, done = {}, time.time(), set()
while len(done) < len(sys.argv) - 1 and time.time() - t0 < 1500:
    for name in sys.argv[1:]:
        run = client.get_run(newest[name])
        for t in (run.run_details.task_details if run.run_details else None) or []:
            if t.display_name in STEPS and t.state in ("RUNNING", "SUCCEEDED", "FAILED") and seen.get((name, t.display_name)) != t.state:
                seen[(name, t.display_name)] = t.state
                print(f"  {int(time.time() - t0):4d}s  {name:32s} {t.display_name:15s} {t.state}", flush=True)
        if run.state in ("SUCCEEDED", "FAILED", "CANCELED") and name not in done:
            done.add(name)
            skipped = [s for s in STEPS if (name, s) not in seen]
            note = f"   (not run: {', '.join(skipped)})" if skipped else ""
            print(f"  {int(time.time() - t0):4d}s  {name:32s} RUN {run.state}{note}", flush=True)
    time.sleep(5)
failed = [n for n in sys.argv[1:] if client.get_run(newest[n]).state != "SUCCEEDED"]
if failed:
    sys.exit(f"runs not successful: {failed}")
PY

# ---------------------------------------------------------------------------------------------
step 5 "Models in the Model Registry (newest version of each)"
for b in "${BRANCHES[@]}"; do
  kf-kit - "$(model_of "${b}")" < "${MLOPS_ROOT}/training/kubeflow/registry.py" | grep -E '^MODEL|VERSION' | sed -n '1p;$p'
done

# ---------------------------------------------------------------------------------------------
step 6 "Serving: one KServe endpoint per model"
for b in "${BRANCHES[@]}"; do
  m="$(model_of "${b}")"
  kubectl -n "${KF}" wait --for=condition=Ready "inferenceservice/${m}" --timeout=300s >/dev/null \
    || echo "  ${m}: endpoint not ready yet (a blocked quality gate leaves the previous version, or none)"
  echo "endpoint ${m}  (data branch ${b}, version $(kubectl -n "${KF}" get inferenceservice "${m}" -o jsonpath='{.metadata.labels.model-version}' 2>/dev/null))"
  kf-kit - "${m}" < "${MLOPS_ROOT}/training/kubeflow/predict.py" | sed 's/^/  /'
done
# ---------------------------------------------------------------------------------------------
step 7 "Tests against the endpoints"
models=(); for b in "${BRANCHES[@]}"; do models+=("$(model_of "${b}")"); done
kf-kit - "${models[@]}" < "${MLOPS_ROOT}/training/kubeflow/test_endpoint.py" || die "endpoint tests failed"

printf '\n\033[1;32mDone.\033[0m Schedules now watch each branch every 2 minutes; stop everything with mlops/training/lab.sh reset\n'

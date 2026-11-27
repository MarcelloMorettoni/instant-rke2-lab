#!/usr/bin/env bash
# Training lab helper: opens every UI of the MLOps lab on a fixed localhost port.
#
#   lab.sh up        start the port-forwards (each one restarts itself if it drops)
#   lab.sh status    cluster health and which URLs answer
#   lab.sh logins    URLs with user names and passwords (reads .state/, prints to your terminal)
#   lab.sh down      stop the port-forwards
#   lab.sh reset     remove what the training exercises created
#   lab.sh pause-datahub     stop DataHub's 7 pods (frees 1.6 CPU and about 3.7 GiB; its data is kept)
#   lab.sh resume-datahub    start DataHub again and wait until it answers (about 5 minutes)
#
# Nothing is installed on the host: these are plain `kubectl port-forward`
# processes bound to 127.0.0.1.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
PF_DIR="${LAB_ROOT}/.state/training-pf"

# name | local port | namespace | service | service port | path used for the health check
FORWARDS=(
  "kubeflow|8080|istio-system|istio-ingressgateway|80|/dex/healthz"
  "mlflow|5001|mlflow|mlflow|5000|/health"
  "jupyterhub|8081|jhub|proxy-public|80|/hub/login"
  "lakefs|8000|lakefs|lakefs|80|/api/v1/healthcheck"
  "gitea|3000|gitea|gitea|3000|/api/healthz"
  "argo|2746|argo|argo-workflows-server|2746|/"
  "datahub|9002|datahub|datahub-datahub-frontend|9002|/admin"
  "ray-dashboard|8265|mr-alpha|sensor-fault-head-svc|8265|/"
)

up() {
  mkdir -p "${PF_DIR}"
  for f in "${FORWARDS[@]}"; do
    IFS='|' read -r name port ns svc sport _ <<<"${f}"
    if [[ -f "${PF_DIR}/${name}.pid" ]] && kill -0 "$(cat "${PF_DIR}/${name}.pid")" 2>/dev/null; then
      echo "${name}: already running"; continue
    fi
    # setsid gives the loop its own process group, so `down` can stop loop and kubectl together.
    setsid bash -c "while true; do kubectl -n '${ns}' port-forward 'svc/${svc}' '${port}:${sport}' --address 127.0.0.1; sleep 2; done" \
      >"${PF_DIR}/${name}.log" 2>&1 < /dev/null &
    echo $! > "${PF_DIR}/${name}.pid"
    echo "${name}: http://localhost:${port}"
  done
  sleep 3; status
}

down() {
  for pidfile in "${PF_DIR}"/*.pid; do
    [[ -f "${pidfile}" ]] || continue
    pid="$(cat "${pidfile}")"
    kill -- "-${pid}" 2>/dev/null || true      # negative pid = the whole process group
    rm -f "${pidfile}"
    echo "stopped $(basename "${pidfile}" .pid)"
  done
}

status() {
  kubectl get nodes --no-headers | awk '{printf "node %-8s %s\n", $1, $2}'
  local bad; bad="$(kubectl get pods -A --no-headers | grep -vcE 'Running|Completed' || true)"
  echo "pods not Running/Completed: ${bad}"
  for f in "${FORWARDS[@]}"; do
    IFS='|' read -r name port _ _ _ path <<<"${f}"
    code="$(curl -s -o /dev/null -m 5 -H 'Accept: text/html' -w '%{http_code}' "http://localhost:${port}${path}" || true)"
    if [[ "${name}" == datahub && "$(kubectl -n datahub get deploy datahub-datahub-gms -o jsonpath='{.spec.replicas}')" == 0 ]]; then
      printf '%-14s paused - run: lab.sh resume-datahub\n' "${name}"; continue
    fi
    printf '%-14s http://localhost:%-5s %s\n' "${name}" "${port}" "$([[ "${code}" =~ ^(2..|30.)$ ]] && echo "ok (${code})" || echo "NOT REACHABLE (${code}) - run: lab.sh up")"
  done
}

logins() {
  # shellcheck disable=SC1090
  for f in mlflow users lakefs gitea; do source "${LAB_ROOT}/.state/mlops-${f}.env"; done
  cat <<EOF
Kubeflow       http://localhost:8080
                 user@example.com / 12341234           project kubeflow-user-example-com (used in the training)
                 alice@example.com / ${ALICE_PASSWORD}     project team-alpha
                 bob@example.com   / ${BOB_PASSWORD}     project team-beta
MLflow         http://localhost:5001
                 mr-alpha / ${TENANT_MR_ALPHA_MLFLOW_PASSWORD}     project mr-alpha (used in the training)
                 kubeflow-user / ${MLFLOW_USER_KUBEFLOW_PASSWORD}     the account Kubeflow jobs log with
                 admin / ${MLFLOW_ADMIN_PASSWORD}
JupyterHub     http://localhost:8081                   sign up with any name and a password of 10+ characters
lakeFS         http://localhost:8000
                 Access Key ID      ${LAKEFS_ACCESS_KEY}
                 Secret Access Key  ${LAKEFS_SECRET_KEY}
Gitea          http://localhost:3000
                 ${GITEA_USER} / ${GITEA_PASSWORD}     also for git clone and git push in a notebook
Argo Workflows http://localhost:2746                   no login (pipelines of the MLflow + Ray projects; namespace mr-alpha)
DataHub        http://localhost:9002                   datahub / datahub
Ray dashboard  http://localhost:8265                   no login (cluster of the sensor-fault endpoint)
EOF
}

reset() {
  # shellcheck disable=SC1090
  source "${LAB_ROOT}/.state/mlops-lakefs.env"
  local kf=kubeflow-user-example-com mr=mr-alpha
  # Parts 1-3
  kubectl -n "${kf}" delete experiment.kubeflow.org training-hpo --ignore-not-found
  kubectl -n "${kf}" delete trainjob training-finetune --ignore-not-found
  kubectl -n "${mr}" delete rayjob training-finetune --ignore-not-found
  # Lesson 5: schedule, pipeline, endpoint
  kubectl -n "${kf}" exec -i deploy/kit -c kit -- python -W ignore - <<'PY' || true
import kfp
c = kfp.Client()
ns = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
e = c.create_experiment("my-model", namespace=ns)
for j in c.list_recurring_runs(experiment_id=e.experiment_id, page_size=100).recurring_runs or []:
    if j.status == "ENABLED":
        c.disable_recurring_run(j.recurring_run_id)
for r in c.list_runs(experiment_id=e.experiment_id, page_size=50, sort_by="created_at desc").runs or []:
    if r.state in ("RUNNING", "PENDING"):
        try:
            c.terminate_run(r.run_id); print("run stopped:", r.display_name)
        except Exception:
            pass
for j in c.list_recurring_runs(experiment_id=e.experiment_id, page_size=100).recurring_runs or []:
    c.delete_recurring_run(j.recurring_run_id); print("schedule deleted:", j.display_name)
for pid in [p.pipeline_id for p in c.list_pipelines(namespace=ns, page_size=100).pipelines or [] if p.display_name in ("my-model-training", "my-model-watch")]:
    for v in c.list_pipeline_versions(pid, page_size=100).pipeline_versions or []:
        c.delete_pipeline_version(pid, v.pipeline_version_id)
    c.delete_pipeline(pid); print("pipeline deleted")
PY
  kubectl -n "${kf}" delete inferenceservice my-model --ignore-not-found
  kubectl -n "${kf}" delete inferenceservice -l trained-by=my-model-training --ignore-not-found   # models of other data branches
  # Lesson 6: schedule, pipeline, endpoint, code, and the model in MLflow
  kubectl -n "${mr}" delete cronworkflow my-ct-every-2min --ignore-not-found
  kubectl -n "${mr}" get workflows -o name | grep -E '/(commit-|my-ct-every-2min-)' | xargs -r kubectl -n "${mr}" delete >/dev/null || true
  kubectl -n "${mr}" delete workflowtemplate my-ct --ignore-not-found
  kubectl -n "${mr}" delete rayservice my-model --ignore-not-found
  kubectl -n "${mr}" delete configmap my-training --ignore-not-found
  kubectl -n "${mr}" exec deploy/kit -c kit -- python -W ignore -c "
import mlflow
try:
    mlflow.MlflowClient().delete_registered_model('my-model'); print('MLflow model my-model deleted')
except Exception:
    pass" || true
  # Lessons 5 and 6: the git repositories go back to their starting point
  "${MLOPS_ROOT}/gitea/seed-repos.sh" || true
  # lakeFS repositories of the exercises
  for repo in training kf-my-data mr-my-data; do
    kubectl -n lakefs exec deploy/lakefs -- env LAKECTL_SERVER_ENDPOINT_URL=http://localhost:8000 \
      LAKECTL_CREDENTIALS_ACCESS_KEY_ID="${LAKEFS_ACCESS_KEY}" LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY="${LAKEFS_SECRET_KEY}" \
      lakectl repo delete "lakefs://${repo}" --yes 2>&1 | grep -i "deleted" || true
  done
  echo "Notebook servers, MLflow runs and Kubeflow model versions are left in place."
}

pause-datahub() {
  kubectl -n datahub scale deploy --all --replicas=0
  kubectl -n datahub scale statefulset --all --replicas=0
  echo "DataHub paused. Its databases stay on their volumes."
}

resume-datahub() {
  local t0; t0=$(date +%s)
  kubectl -n datahub scale statefulset --all --replicas=1
  kubectl -n datahub rollout status statefulset --timeout=10m
  kubectl -n datahub scale deploy --all --replicas=1
  kubectl -n datahub rollout status deploy --timeout=15m
  echo "DataHub back after $(( $(date +%s) - t0 ))s: http://localhost:9002"
}

case "${1:-}" in
  up|down|status|logins|reset|pause-datahub|resume-datahub) "$1" ;;
  *) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

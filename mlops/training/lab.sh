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
  for f in mlflow users lakefs; do source "${LAB_ROOT}/.state/mlops-${f}.env"; done
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
DataHub        http://localhost:9002                   datahub / datahub
Ray dashboard  http://localhost:8265                   no login (cluster of the sensor-fault endpoint)
EOF
}

reset() {
  # shellcheck disable=SC1090
  source "${LAB_ROOT}/.state/mlops-lakefs.env"
  kubectl -n kubeflow-user-example-com delete experiment.kubeflow.org training-hpo --ignore-not-found
  kubectl -n kubeflow-user-example-com delete trainjob training-finetune --ignore-not-found
  kubectl -n mr-alpha delete rayjob training-finetune --ignore-not-found
  kubectl -n lakefs exec deploy/lakefs -- env LAKECTL_SERVER_ENDPOINT_URL=http://localhost:8000 \
    LAKECTL_CREDENTIALS_ACCESS_KEY_ID="${LAKEFS_ACCESS_KEY}" LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY="${LAKEFS_SECRET_KEY}" \
    lakectl repo delete lakefs://training --yes 2>&1 | tail -1 || true
  echo "Notebook servers, MLflow runs and model versions are left in place: delete them in their UIs if you want."
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

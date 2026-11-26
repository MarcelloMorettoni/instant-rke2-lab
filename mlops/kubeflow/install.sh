#!/usr/bin/env bash
# Full Kubeflow platform from kubeflow/manifests, pinned in ../lib.sh.
# Uses the upstream single-command install (example/kustomization.yaml) so the
# evaluation reflects what upstream ships, not a trimmed-down variant.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

SRC="${MLOPS_CACHE}/kubeflow-manifests-${KUBEFLOW_MANIFESTS_VERSION}"
RENDERED="${MLOPS_CACHE}/kubeflow-${KUBEFLOW_MANIFESTS_VERSION}.yaml"

check_host_disk

if [[ ! -d "${SRC}" ]]; then
  log "Cloning kubeflow/manifests ${KUBEFLOW_MANIFESTS_VERSION}"
  mkdir -p "${MLOPS_CACHE}"
  git clone -q --depth 1 --branch "${KUBEFLOW_MANIFESTS_VERSION}" \
    https://github.com/kubeflow/manifests "${SRC}"
fi

ensure_kustomize
log "Rendering example/kustomization.yaml with kustomize ${KUSTOMIZE_VERSION}"
# Not hermetic: the Pipelines overlay pulls Argo Workflows CRDs from GitHub at
# build time, and kustomize gives that fetch 27s. Retry instead of failing.
for try in 1 2 3 4 5; do
  if "${KUSTOMIZE}" build "${SRC}/example" > "${RENDERED}.tmp" 2> "${MLOPS_CACHE}/kustomize.log"; then
    mv "${RENDERED}.tmp" "${RENDERED}"; break
  fi
  echo "render attempt ${try} failed: $(grep -o 'hit [0-9]*s timeout.*' "${MLOPS_CACHE}/kustomize.log" || tail -c 200 "${MLOPS_CACHE}/kustomize.log")"
  (( try < 5 )) || exit 1
  sleep 10
done

# CRDs and webhooks are in the same stream as the resources that need them, so
# the first passes fail on purpose; upstream's own instruction is to retry.
log "Applying (retries until CRDs and webhooks are ready)"
attempt=0
until kubectl apply --server-side --force-conflicts -f "${RENDERED}" > "${MLOPS_CACHE}/apply.log" 2>&1; do
  attempt=$((attempt + 1))
  echo "attempt ${attempt}: $(grep -ciE 'error|unable' "${MLOPS_CACHE}/apply.log") errors, retrying in 20s"
  if (( attempt >= 30 )); then
    echo "still failing after ${attempt} attempts — see ${MLOPS_CACHE}/apply.log" >&2
    exit 1
  fi
  check_host_disk
  sleep 20
done
echo "applied cleanly after ${attempt} retries"

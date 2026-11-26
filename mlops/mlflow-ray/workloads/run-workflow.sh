#!/usr/bin/env bash
# Submits one run of the w3-ct WorkflowTemplate and waits for it.
#   run-workflow.sh <namespace> <run-name>
source "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"
NS="$1"; NAME="$2"; t0=$(date +%s)
kubectl -n "${NS}" create -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: ${NAME}
  labels: {workflows.argoproj.io/controller-instanceid: mlflow-ray}
spec:
  workflowTemplateRef: {name: w3-ct}
YAML
until phase=$(kubectl -n "${NS}" get workflow "${NAME}" -o jsonpath='{.status.phase}'); [[ "${phase}" == Succeeded || "${phase}" == Failed || "${phase}" == Error ]]; do
  (( $(date +%s) - t0 > ${TIMEOUT:-1500} )) && { echo "timeout"; break; }
  sleep 5
done
echo "workflow ${NAME} phase=${phase} wall=$(( $(date +%s) - t0 ))s"
kubectl -n "${NS}" get workflow "${NAME}" -o json | jq -r '.status.nodes | to_entries | map(.value) | sort_by(.startedAt) | .[] | select(.type!="StepGroup" and .type!="Steps") | "  \(.displayName|.[0:12]) \(.phase) \(.startedAt[11:19])-\((.finishedAt // "        ")[11:19]) \(.message // "" | .[0:90])"'
[[ "${phase}" == Succeeded ]]

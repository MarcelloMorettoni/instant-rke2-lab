#!/usr/bin/env bash
# What CI does on every push (run by .gitea/workflows/train.yaml in the project's CI runner).
#
#   1. Publish the code: the ConfigMap my-training, mounted by every pipeline step.
#   2. Publish the pipeline, with the git commit written into it.
#   3. Start one run now with retrain=yes, because the code changed.
#   4. Switch the 2-minute schedule back on. It is off while the run of step 3 takes
#      the current data, so the two never train on the same commit.
#
#   ci/deploy.sh <git commit>
set -euo pipefail
commit="$1"; short="${commit:0:8}"; name="commit-${short}-$(date +%H%M%S)"

kubectl create configmap my-training --dry-run=client -o yaml \
  --from-file=steps.py --from-file=train.py --from-file=serve.py --from-file=rayservice.yaml | kubectl apply -f -
sed -e "s/GIT_COMMIT_PLACEHOLDER/${commit}/" -e "s/suspend: false/suspend: true/" workflow.yaml | kubectl apply -f -

kubectl create -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: ${name}
  labels: {workflows.argoproj.io/controller-instanceid: mlflow-ray}
spec:
  workflowTemplateRef: {name: my-ct}
  arguments: {parameters: [{name: retrain, value: "yes"}]}
YAML

echo "waiting for its first step (detect) before the schedule goes back on"
for _ in $(seq 1 48); do
  phase="$(kubectl get workflow "${name}" -o json | python3 -c 'import json, sys
nodes = (json.load(sys.stdin).get("status") or {}).get("nodes") or {}
print(next((n.get("phase", "") for n in nodes.values() if n.get("displayName") == "detect"), ""))')"
  [[ "${phase}" == Succeeded || "${phase}" == Failed || "${phase}" == Error ]] && break
  sleep 5
done
kubectl patch cronworkflow my-ct-every-2min --type=merge -p '{"spec":{"suspend":false}}'
echo "run ${name} started; schedule my-ct-every-2min is on"

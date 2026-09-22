#!/usr/bin/env bash
# make soft-tenancy: every step of this folder, in order, unattended.
#
#   ./up.sh              steps 00 to 13, running the three verify scripts on the way
#   ./up.sh 06           resume from step 06 (after fixing something, say)
#   VERIFY=0 ./up.sh     skip the verify scripts (05, 11, 13)
#   ST_PASSWORD=... ./up.sh   another password for the Grafana logins (default: test-tenant)
#
# The result: tenants a, b and c.
#   network   a -> c allowed, c -> a blocked, b sees only b
#   Grafana   alice (Tenant A) sees a and c, bob sees b, carol sees c, ops sees everything
#
# Every step is idempotent, so running it again is safe. The README walks
# through the same steps by hand, with the why.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
require_cluster
require_helm
command -v jq >/dev/null || die "jq is required"
cd "${HERE}"

FROM="${1:-00}"
[[ "${FROM}" =~ ^[0-9]{1,2}$ ]] || die "usage: $0 [first step, 00-13]"
VERIFY="${VERIFY:-1}"

run() {  # run <step> <title> <command...>: skipped when before FROM
  local n=$1 title=$2
  shift 2
  (( 10#${n} >= 10#${FROM} )) || return 0
  echo
  log "════ Step ${n} · ${title}"
  "$@"
}
verify() {  # verify <step> <script>: a verify step, unless VERIFY=0
  [[ "${VERIFY}" == 1 ]] || { (( 10#$1 >= 10#${FROM} )) && warn "Step $1 skipped (VERIFY=0)"; return 0; }
  run "$1" "verify" "./$2"
}

as_tenants() {  # as_tenants <dir> <file prefix>: each tenant applies its own file, as its own user
  local t user
  for t in a b c; do
    case "${t}" in a) user=alice ;; b) user=bob ;; c) user=carol ;; esac
    kubectl --as "${user}" apply -f "$1/$2-${t}.yaml"
  done
}
step01() {
  kubectl apply -f 01-namespaces/namespace-guard.yaml
  kubectl apply -f 01-namespaces/namespaces.yaml
}
step04() {
  as_tenants 04-demo-apps tenant
  for ns in tenant-a tenant-b tenant-c; do
    kubectl -n "${ns}" wait --for=condition=Available deploy --all --timeout=300s
  done
}
step12() {
  ./12-kgateway-ingress/install.sh
  as_tenants 12-kgateway-ingress route-tenant
}

run 00 "Cilium DNS: NXDOMAIN for blocked names"   ./00-cilium-dns/apply.sh
run 01 "Namespaces and the admission guard"       step01
run 02 "Tenant RBAC and quotas"                   kubectl apply -f 02-tenant-guardrails/
run 03 "Tenant network baselines"                 kubectl apply -f 03-tenant-isolation/
run 04 "Workloads, deployed by the tenants"       step04
verify 05 05-verify-network.sh
run 06 "Loki, Mimir, Tempo, Pyroscope"            ./06-observability-backends/install.sh
run 07 "Read gateway (kgateway)"                  ./07-read-gateway/install.sh
run 08 "Collectors: Alloy and trace receivers"    ./08-collectors/install.sh
run 09 "Grafana, one org per tenant"              ./09-grafana/install.sh
run 10 "Lock down the observability namespace"    kubectl apply -f 10-observability-lockdown/policies.yaml
verify 11 11-verify-observability.sh
run 12 "Ingress with kgateway"                    step12
verify 13 13-verify-ingress.sh

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
echo
ok "Soft tenancy is up: tenants a, b and c."
cat <<EOF

  Network   tenant a -> tenant c: allowed    tenant c -> tenant a: blocked    tenant b: only itself

  Grafana   http://grafana.platform.lab:30182   (add "${NODE_IP} grafana.platform.lab" to /etc/hosts)
            or: kubectl -n ${OBS_NS} port-forward svc/grafana 3000:80   ->  http://localhost:3000

            alice / ${ST_PASSWORD}   Tenant A: tenant-a and tenant-c
            bob   / ${ST_PASSWORD}   Tenant B: tenant-b
            carol / ${ST_PASSWORD}   Tenant C: tenant-c
            ops   / ${ST_PASSWORD}   Platform: everything
            admin / ${ST_PASSWORD}

  Apps      curl -H 'Host: web.tenant-a.lab' http://${NODE_IP}:30180/   (tenant-b :30181, tenant-c :30183)

  Re-check  make soft-tenancy-verify        Remove   make soft-tenancy-clean
EOF

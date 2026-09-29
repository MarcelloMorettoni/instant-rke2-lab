# ADR 0002 · The platform decides the tenant, from the namespace

**Status:** accepted (revised 2026-09-29 for OpenTelemetry) · **Date:** 2026-09-28

## Context
Loki trusts the `X-Scope-OrgID` header without authentication. If workloads could choose
it, any compromised or misconfigured pod could write into another tenant, or get around its
limits.

## Decision
- The platform's **OpenTelemetry agents** decide the tenant of every log record from the
  **namespace**:
  - **stdout logs**: the namespace comes from the log file path, which the kubelet writes;
  - **OTLP from an SDK**: every `k8s.*` and tenant attribute the app sent is deleted, and the
    namespace is looked up from the pod behind the connection's **source IP**
    (`k8s_attributes`, `from: connection`).
- The mapping from namespace to tenant is generated from `tenants/tenants.yaml` (OTTL statements).
- Namespaces that match no tenant go to `unassigned` (platform-only), never to a customer
  tenant.
- Only the agents can reach the OTel gateway, and only the gateway can reach Loki
  (NetworkPolicies).

## Alternatives
- **Tenant from a namespace label**: equally trustworthy; the `k8s_attributes` processor can
  extract namespace labels. Switch if naming conventions can't be enforced.
- **Apps send their tenant (header or attribute)**: rejected, because a tenant would choose
  its own identity.

## Consequences
Namespace naming becomes part of the security model (docs/02). Verified by
`scripts/pipeline-test.sh`: a forged OTLP push can't get into the tenant it claims, and a
mutation test proves the check fails without the stripping step.
`scripts/kind-e2e.sh` runs the same check against a real Kubernetes API; it is written but not yet run here.

# ADR 0007 · OpenTelemetry Collector: agents per node, gateway per tenant queue

**Status:** accepted · **Date:** 2026-09-29

## Context
The bank's standard for telemetry is OpenTelemetry. Collection must:
- read container stdout without app changes;
- accept OTLP from apps with an SDK;
- decide the tenant in a way the tenant can't influence;
- mask sensitive data;
- survive downstream outages;
- keep one tenant's problems away from the others.

## Decision
- **Upstream OpenTelemetry Collector (contrib)**, pinned (collector 0.160.0, chart 0.173.1).
  Images are mirrored to ACR.
- **Agent** (DaemonSet, ns `otel-agent`):
  - receivers: `file_log` (`container` parser) and `otlp`;
  - untrusted attributes deleted; `k8s_attributes` (by pod UID for files, by connection IP
    for OTLP);
  - tenant (OTTL, generated) and masking (OTTL);
  - persistent queue on the node.
- **Gateway** (StatefulSet, ns `otel`, 3 pods):
  - `routing` connector by tenant;
  - **one `otlp_http` exporter per tenant**, with its own persistent queue (size from the
    tier) and `X-Scope-OrgID`;
  - pushes to Loki's native OTLP endpoint.
- **Loki `otlp_config`**: only 4 bounded resource attributes become labels; the rest is
  structured metadata.
- Configs are generated from the tenant registry and checked with `otelcol validate` and an
  end-to-end Docker test.

## Alternatives
- **Grafana Alloy**, as in the RKE2 lab: capable, and itself a collector distribution, but
  not the bank's standard, and its config language is vendor-specific.
- **Agents only**: one exporter per tenant on every node, or a shared queue where one
  throttled tenant blocks the rest.
- **`headers_setter` from an attribute**: its `from_attribute` reads the client's auth
  data, not resource attributes, so it can't carry the tenant.
- **Loki exporter**: removed upstream in favour of OTLP.

## Consequences
- One exporter and one pipeline per tenant in the gateway config, which is generated, so the
  config grows linearly with tenants. At several hundred tenants, consider sharding tenants
  across gateway groups.
- The same collectors can later carry traces and metrics.

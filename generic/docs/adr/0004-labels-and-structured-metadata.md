# ADR 0004 · Four stream labels; everything else as structured metadata

**Status:** accepted (revised 2026-09-29 for OTLP) · **Date:** 2026-09-28

## Context
Every unique label set is a Loki stream. Per-pod labels (pod name, pod UID, node, file path)
multiply streams with every deployment, and are the most common cause of Loki ingester memory
problems and slow queries. With OTLP ingestion, Loki by default turns about 18 resource
attributes into labels, including `k8s.pod.name` and `service.instance.id`.

## Decision
Set Loki `limits_config.otlp_config` with `ignore_defaults: true`, so exactly these resource
attributes become labels:

| OTel attribute | Loki label |
|---|---|
| `k8s.cluster.name` | `k8s_cluster_name` |
| `k8s.namespace.name` | `k8s_namespace_name` |
| `k8s.container.name` | `k8s_container_name` |
| `service.name` | `service_name` |

- Everything else (pod, UID, node, workload names, trace/span IDs, log attributes) is
  **structured metadata**: queryable with a filter such as `| k8s_pod_name="api-7f9c"`, but it
  doesn't create streams.
- The collectors delete `log.file.path`, and the internal `obs.tenant` attribute never reaches Loki.
- Verified end to end (`scripts/pipeline-test.sh` checks the label set exactly).

## Consequences
- Queries by pod use a filter instead of a selector, which is slightly slower on huge
  namespaces.
- Tenants can't add labels themselves; high-cardinality fields stay in attributes or the body.
- Label names differ from the RKE2 lab (Alloy: `namespace`, `container`); dashboards use the
  OTel names.

# 01 · Architecture

![Architecture overview](../diagrams/01-architecture-overview.png)

## Scope and assumptions

- **One shared AKS cluster**, owned by the platform team. Tenants (application
  teams, business lines) get namespaces. Namespace isolation (RBAC, quotas,
  NetworkPolicies, Pod Security) is already in place and is the platform's job.
- The bank has standardised on **OpenTelemetry**. Collection is the upstream OpenTelemetry
  Collector, and the wire protocol is **OTLP from the node to Loki**.
- Workloads either **log to stdout/stderr** (nothing to change), or **export
  logs with an OpenTelemetry SDK** to the collector on their node.
- People read logs in **Grafana**, signing in with the bank's **Entra ID**.
- AKS runs in a region with **3 availability zones**, with Azure CNI (Cilium or
  Calico), the OIDC issuer and Workload Identity enabled, a private API server,
  and egress through the hub firewall.
- Sizing reference: **~1 TB/day of raw logs**, tens to a few hundred tenants
  ([05 · Sizing](05-sizing-and-capacity.md)).

## Components

| Component | Runs as | Replicas (M profile) | State | Why it exists |
|---|---|---|---|---|
| **OTel agent** | DaemonSet, ns `otel-agent` | 1 per node | read checkpoints + export queue on the node (`/var/lib/otelcol`) | Reads container logs; accepts OTLP from pods on its node; decides the tenant; masks secrets |
| **OTel gateway** | StatefulSet, ns `otel` | 3 (one per zone) | **one persistent queue per tenant** on a zonal SSD | Routes by tenant; isolates tenants from each other; buffers Loki outages; OTLP → Loki |
| **Distributor** | Deployment, ns `loki` | 3 → 9 (HPA) | none | Native OTLP endpoint; per-tenant limits; replicates ×3 |
| **Ingester** | 3 StatefulSets, one per zone | 2 per zone | WAL on a zonal Premium SSD (CMK) | Holds the last ~2 h, builds chunks, flushes to Blob |
| **Query frontend** | Deployment | 2 | none | Splits and shards queries; **results cache**; per-tenant queue |
| **Query scheduler** | Deployment | 2 | none | Fair queue per tenant |
| **Querier** | Deployment | 4 → 16 (HPA) | none | Runs queries on Blob chunks and ingesters' recent data |
| **Index gateway** | StatefulSet | 3 (one per zone) | index on local disk | Serves the TSDB index |
| **Compactor** | StatefulSet | 1 | working dir on disk | Compacts the index; per-tenant **retention**; deletes |
| **Memcached** (chunks, results) | StatefulSets | 3 + 2 | memory | Read-path caches ([08](08-design-questions.md#caching)) |
| **Overrides exporter**, **rollout-operator** | Deployments | 1 each | none | Limits as metrics; ingester upgrades one zone at a time |
| **obs-gateway** (read gateway) | kgateway (Envoy) | 3 → 9 | none | The only way into the read path; sets the tenant header |
| **Grafana** | Deployment, ns `grafana` | 2 | PostgreSQL | UI, one org per tenant, alerting |
| **External Secrets** | Deployment | 1+ | none | Key Vault → Kubernetes Secrets |
| **grafana-sync** | CronJob, ns `grafana` | every 10 min | none | Orgs + one Loki data source per tenant, with the view's current key |

Azure side (Terraform, [`infra/terraform`](../infra/terraform)):
- Blob Storage (GZRS)
- Key Vault (HSM keys)
- managed identities with Workload Identity
- a disk encryption set
- three zonal node pools
- PostgreSQL flexible server (zone-redundant HA)
- managed Prometheus rule groups
- diagnostic settings

## Write path: OpenTelemetry end to end

![Write path](../diagrams/02-write-path.png)

1. **Stdout**: the kubelet writes each container's output to
   `/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log`. The **agent** on that node
   reads it with the `file_log` receiver. The `container` parser takes namespace, pod and
   container from the **file path**, which the kubelet writes and the app can't change.
2. **OTel SDK**: the app exports OTLP to `otel-agent.otel-agent.svc:4317` (gRPC) or `:4318`
   (HTTP). The Service's `internalTrafficPolicy: Local` keeps the connection on the app's own
   node. The agent:
   - **deletes** every `k8s.*` and tenant attribute the app sent;
   - asks the Kubernetes API which pod owns the connection's **source IP** (`k8s_attributes`,
     association `from: connection`).

   An app can say what it likes about itself; the platform decides who it is.
3. The agent then:
   - adds workload metadata;
   - sets `service.name` if the app didn't;
   - sets the tenant from the namespace (**generated** from `tenants.yaml`);
   - **masks** card numbers, IBANs and bearer tokens in bodies *and* attributes;
   - queues the result in a **persistent queue on the node's disk** (2 GiB).
4. The agent sends OTLP/gRPC, zstd-compressed, round-robin over the **gateway** pods. Each
   gateway pod:
   - routes every record by tenant into **that tenant's own exporter and persistent queue**
     on its zonal SSD;
   - pushes to Loki's OTLP endpoint (`/otlp/v1/logs`) with `X-Scope-OrgID: <tenant>`.
5. The **distributor** checks the tenant's limits and turns OTLP into Loki streams. Only
   four bounded resource attributes become stream labels:

   | OTel attribute | Loki label |
   |---|---|
   | `k8s.cluster.name` | `k8s_cluster_name` |
   | `k8s.namespace.name` | `k8s_namespace_name` |
   | `k8s.container.name` | `k8s_container_name` |
   | `service.name` | `service_name` |

   Everything else (pod, node, trace ID, log attributes) becomes structured metadata.
   The distributor then writes each stream to **3 ingesters, one per zone**, and
   acknowledges once 2 have it.
6. The ingesters flush compressed chunks to Blob. The compactor applies each tenant's retention.

Why two collector tiers, and what each buffer protects against:
[08 · Design questions](08-design-questions.md#why-an-agent-and-a-gateway) and
[ADR 0007](adr/0007-opentelemetry-collection.md).

## Read path

![Read path](../diagrams/03-read-path-and-tenancy.png)

1. The user signs in to Grafana with Entra ID. Their security groups decide their org and role.
2. Each org has one Loki data source: `http://obs-gateway.loki.svc:8080/<view>/`, plus the
   view's key.
3. The **read gateway** checks the key, **sets** `X-Scope-OrgID`, and forwards to the query frontend.
4. The **query frontend** asks the **results cache**, then splits and shards the rest. The
   **queriers** read the index (through the index gateways), then the chunks (**chunks cache**,
   then Blob), then recent data from the ingesters.

![Caching](../diagrams/07-caching.png)

## Why this shape

| Decision | Alternative | Why this one | ADR |
|---|---|---|---|
| Distributed Loki, zone-aware ingesters | Simple Scalable | Independent scaling; a zone can fail without failing writes | [0001](adr/0001-distributed-zone-aware-loki.md) |
| Platform decides the tenant from the namespace | Apps send their own tenant header | A tenant can't write into another tenant | [0002](adr/0002-tenant-is-the-namespace.md) |
| Read gateway with one view per org | OAuth passthrough; nginx | The header comes only from the platform | [0003](adr/0003-read-gateway-views.md) |
| Few labels; the rest as structured metadata | Pod as a label | Bounded stream count | [0004](adr/0004-labels-and-structured-metadata.md) |
| Blob GZRS + Workload Identity + CMK | Account keys; LRS | No secrets; survives a zone and (with delay) a region | [0005](adr/0005-azure-blob-workload-identity.md) |
| **No Kafka / Event Hubs** | A bus in front of Loki | Every hop already has a durable buffer | [0006](adr/0006-no-kafka-buffer.md) |
| **OpenTelemetry Collector, agent + gateway** | Grafana Alloy; agent only | Bank standard; per-tenant queues; vendor-neutral OTLP | [0007](adr/0007-opentelemetry-collection.md) |
| **Memcached caches on the read path only** | Redis; no cache; write cache | Loki's tested design; loss costs speed, never data | [0008](adr/0008-caching.md) |
| **Entra ID directly for Grafana SSO** | Keycloak brokering Entra ID | Existing MFA/CA/PIM; no extra critical system; tenants aren't token claims | [0009](adr/0009-entra-id-not-keycloak.md) |

## Versions (pinned in [`scripts/lib.sh`](../scripts/lib.sh))

| | Version |
|---|---|
| OpenTelemetry Collector | chart `open-telemetry/opentelemetry-collector` 0.173.1 → `otelcol-contrib` 0.160.0 |
| Loki | chart `grafana/loki` 7.3.0 → Loki 3.6.11 (native OTLP ingestion) |
| Grafana | chart `grafana-community/grafana` 13.2.5 → Grafana 13.2 |
| kgateway | v2.4.5 (Gateway API v1.6.1) |
| External Secrets | chart 2.11.0 |
| Terraform azurerm | ~> 4.40 (tested with 4.81) |

Loki, Grafana and kgateway match the RKE2 lab ([`../soft-tenancy`](../../soft-tenancy)).
The lab collects with Grafana Alloy; this design uses the OpenTelemetry Collector.

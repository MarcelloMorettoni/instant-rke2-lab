# Components and their purpose

Every component of the log platform, grouped by layer. The design behind them is in
[01 · Architecture](01-architecture.md). The two installations (everything in the cluster,
or with Azure services) are in [10 · Installations](10-installations.md). Plain YAML for every
component: [`manifests/`](../manifests/).

![Architecture overview](../diagrams/01-architecture-overview.png)

## Collection (OpenTelemetry)

| Component | Runs as | Purpose |
|---|---|---|
| **OTel agent** | DaemonSet, ns `otel-agent`, one pod per node | Reads container stdout from the node, and accepts OTLP from apps on the same node. Works out the tenant from the namespace and ignores any identity an app claims. Masks card numbers, IBANs and tokens. Writes to Kafka, through a disk queue on the node. |
| **OTel gateway** | StatefulSet, ns `otel`, 3 pods (one per zone) | Reads Kafka as one consumer group. Routes logs by tenant, with a separate disk queue and connection to Loki for each tenant, so a throttled tenant doesn't block the others. Sets the tenant header on the way to Loki. |

## Buffer between the tiers (Kafka)

| Component | Runs as | Purpose |
|---|---|---|
| **Kafka cluster `logs`** | Strimzi, ns `kafka`: 3 brokers (one per zone) + 3 KRaft controllers | Holds every log record, 3 copies in 3 zones, for 24 h. A gateway or Loki outage's backlog waits here, off the nodes, and is replayed in order. Another consumer (SIEM) could read the same topic. |
| **Topic `otel-logs`** | KafkaTopic, 24 partitions | OTLP records, keyed per pod and container, so each stream stays in order. |
| **Users `otel-agent`, `otel-gateway`** | KafkaUser, SCRAM-SHA-512 over TLS | Agents may only write, gateways may only read. Nobody else can reach the brokers (NetworkPolicy). |
| **Kafka Exporter** | Deployment, ns `kafka` | Consumer lag and replica health as metrics, for the Kafka alerts. |
| **Strimzi operator** | Deployment, ns `platform-operators` | Runs Kafka: rolling upgrades, certificates inside the cluster, topics, users. |

## Log storage (Loki)

| Component | Runs as | Purpose |
|---|---|---|
| **Distributor** | Deployment, 3 → 9 (autoscaled) | Loki's entry point for OTLP. Enforces each tenant's limits and sends every stream to 3 ingesters, one per zone. |
| **Ingester** | 3 StatefulSets, 2 per zone | Holds the last ~2 h of logs, protected by a write-ahead log on zonal disk. Builds compressed chunks and writes them to Blob. |
| **Compactor** | StatefulSet, 1 | Compacts the index, deletes data past each tenant's retention, and runs deletion requests. |
| **Overrides exporter** | Deployment, 1 | Publishes each tenant's limits as metrics, for usage-versus-quota dashboards. |
| **Rollout operator** | Deployment, 1 | Upgrades ingesters one zone at a time. |

## Queries and caching

| Component | Runs as | Purpose |
|---|---|---|
| **Query frontend** | Deployment, 2 | Splits queries into 1-hour slices, shards them, and checks the results cache first. |
| **Query scheduler** | Deployment, 2 | Queues work fairly per tenant, so one heavy tenant can't starve the others. |
| **Querier** | Deployment, 4 → 16 (autoscaled) | Runs the queries against stored chunks and the ingesters' recent data. |
| **Index gateway** | StatefulSet, 3 | Serves the index from local disk, so queriers don't each download it. |
| **Results cache** | Memcached, 2 × 2 GB | Caches query results for 12 h, so dashboard refreshes are cheap. |
| **Chunks cache** | Memcached, 3 × 8 GB | Caches log chunks read from Blob, cutting storage reads and latency. |

Why there is caching only on the read path, and why Kafka sits between the collector tiers:
[08 · Design questions](08-design-questions.md).

## Access

| Component | Runs as | Purpose |
|---|---|---|
| **Read gateway (`obs-gateway`)** | kgateway (Envoy), 3 → 9 | The only way to query Loki. Each Grafana org has its own view, opened only by that org's key. It sets the tenant header itself and refuses pushes and deletes. |
| **Grafana** | Deployment, 2, ns `grafana` | The UI: one org per tenant, alerting. Sign-in via `auth.provider` (Entra ID, Keycloak, OIDC, or mock users on test clusters), plus a local `admin` (initial password `change-me-now`). |
| **Grafana ingress** | kgateway, internal load balancer | HTTPS access to Grafana from the bank's network only. |
| **External Secrets Operator** | Deployment (Azure) | Copies secrets from Key Vault into Kubernetes, so none sit in git or Helm values. Without Key Vault (generic), the chart generates the secrets and keeps them across upgrades. |
| **grafana-sync** | CronJob, ns `grafana`, every 10 min | Creates one Grafana org per tenant and keeps each org's Loki data source pointed at its view with the current key, so key rotations apply by themselves. |

## Services in the cluster (generic installation)

| Component | Runs as | Purpose |
|---|---|---|
| **Keycloak** | Keycloak operator, ns `keycloak`, 2 instances | Grafana's sign-in: realm `obs` with one group per tenant role and the `grafana` client. Optionally passes sign-in on to Entra ID. Served on Grafana's load balancer. |
| **PostgreSQL** | Percona operator, ns `postgres` (brought by the team) | Grafana's and Keycloak's database. The chart copies each user's Secret into the namespace that uses it. |
| **Prometheus Operator** | the cluster's (e.g. kube-prometheus-stack) | Scrapes the PodMonitors and evaluates the PrometheusRule (the same alerts as on Azure). |
| **Object storage (S3 API)** | optional (`overlays/s3-storage.yaml`) | Instead of Azure Blob: chunks and index on any S3-compatible store. |

## Azure services (Terraform)

| Component | Purpose |
|---|---|
| **Azure Blob Storage (GZRS)** | Stores all chunks and the index. Replicated across 3 zones plus the paired region, reachable only through a private endpoint, with no access keys, encrypted with the bank's own key. |
| **Key Vault (premium, HSM-backed keys)** | Holds the encryption keys for Blob and disks, the read-gateway keys, and the Grafana secrets. |
| **Managed identities (Workload Identity)** | Let Loki and External Secrets reach Azure without any stored credentials. |
| **Zonal node pools (`loki1`/`2`/`3`)** | Dedicated nodes, one pool per zone, so the autoscaler adds capacity in the zone that needs it. |
| **Disk encryption set** | Encrypts the ingester, gateway-queue and index disks with the bank's own key. |
| **PostgreSQL flexible server** | Grafana's database, with zone-redundant HA and geo-redundant backups. |
| **Entra ID** | The default Grafana sign-in: security groups decide which org a user lands in and with what role. Also Workload Identity for Loki and External Secrets. |
| **Keycloak / OIDC provider** (optional) | Grafana sign-in instead of Entra ID (`auth.provider: keycloak` or `oidc`): the token's groups claim decides the org and role. |
| **Azure Monitor managed Prometheus** | Scrapes Loki, the collectors and the gateway, and raises the alerts. |
| **Log Analytics / SIEM** | Audit logs of who accessed the storage, Key Vault and database. |

## Enforced across all layers

| Component | Purpose |
|---|---|
| **NetworkPolicies** | Tenant pods can reach only their node's agent. Only agents can write to Kafka and only gateways read it; only the gateway can push to Loki, and only the read gateway can query it. |
| **Tenant registry (`tenants.yaml`)** | The one file that drives the per-tenant mapping, limits, queues, read views and Grafana orgs. |
| **Helm charts** | `log-platform-operators` (CRDs, kgateway, Strimzi, Keycloak operator, External Secrets) and `log-platform` (everything above), configured by one folder per environment: `azure` or `generic` ([09](09-helm-charts.md)). |

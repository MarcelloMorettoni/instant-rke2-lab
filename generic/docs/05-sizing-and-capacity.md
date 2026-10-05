# 05 · Sizing and capacity

These numbers are **starting points**. Loki's cost depends on **active streams**
as much as on bytes, and on how people query. Confirm them with a load test
before go-live.

## Profiles

| | **S** | **M** (chart defaults) | **L** |
|---|---|---|---|
| Raw logs / day | ≤ 200 GB | ~1 TB | ~5 TB |
| Peak ingest (≈ 3× average) | ~7 MB/s | ~35 MB/s | ~175 MB/s |
| Active streams (all tenants) | ≤ 100 k | ~300 k | ~1.5 M |
| Distributors | 3 (1 CPU / 1 Gi) | 3 → 9 | 6 → 24 (2 CPU / 2 Gi) |
| Ingesters | 3 (1/zone), 2 CPU / 8 Gi | **6 (2/zone), 4 CPU / 16 Gi** | 12-15 (4-5/zone), 8 CPU / 32 Gi |
| Ingester PVC | 50 Gi | 100 Gi | 200 Gi, Premium SSD v2 |
| Queriers | 2 → 6 | 4 → 16, 2 CPU / 6 Gi | 16 → 64 |
| Query frontend / scheduler | 2 / 2 | 2 / 2 | 3 / 3 |
| Index gateways | 2 | 3 | 3-6 |
| Chunks cache | 1 × 4 GB | 3 × 8 GB | 6 × 16 GB |
| Loki nodes (per zone) | 1-2 × D8ds_v5 | **2-5 × D16ds_v5** | 5-12 × D16ds_v5 / E16ds_v5 |

## Collectors

| | S | M | L |
|---|---|---|---|
| OTel agent (per node) | 100m / 256 Mi | 200m / 256 Mi (limit 1 Gi) | 500m / 512 Mi (limit 2 Gi) |
| Agent node queue | 1 GiB | 2 GiB | 4 GiB |
| OTel gateway pods | 3 × 1 CPU / 2 Gi | **3 × 2 CPU / 4 Gi** | 6-9 × 4 CPU / 8 Gi |
| Gateway PVC per pod | 50 Gi | **100 Gi** | 250 Gi |

- **Gateway queue per pod** = the sum of every tenant's `gatewayQueueMiB`. The example
  registry gives 15 GiB. Keep the PVC above ~2× that sum, for compaction headroom.
- **How long it lasts**: (queue per pod × pods) ÷ ingest rate.
  M: 45 GiB ÷ ~12 MB/s ≈ 1 h of every tenant's logs while Loki is down. With Kafka, a long
  Loki outage waits in Kafka instead (below), and the gateway queues mainly keep a throttled
  tenant away from the others. Without Kafka, size them for the outage you want to ride out.
- Scale the gateway in steps of 3 (one per zone), never with an HPA: a removed pod's queue
  waits on its PVC until the pod returns.
- Config size grows with tenants (one exporter + pipeline each). Past a few hundred
  tenants, run several gateway groups, each serving a shard of tenants.

## Kafka

| | S | M (chart defaults) | L |
|---|---|---|---|
| Brokers | 3 (or 3 dual-role, `test-cluster.yaml`) | **3 × 2 CPU / 8 Gi** (heap 3 GiB) | 6 × 4 CPU / 16 Gi |
| KRaft controllers | in the brokers (`dualRole`) | 3 × 0.25 CPU / 1 Gi, 20 Gi disk | 3 × 0.5 CPU / 2 Gi |
| Broker disk | 100 Gi | **500 Gi** | 2 Ti, Premium SSD v2 |
| Partitions of `otel-logs` | 6-12 | **24** | 48-96 |
| Retention | 24 h | **24 h** | 12-24 h |

- **What goes into Kafka**: the agents' OTLP batches, zstd-compressed. OTLP adds the
  resource and log attributes (≈ 1.5× the raw line), and zstd takes ~6-8× off.
  M: 1 TB/day raw → **≈ 200-250 GB/day** in Kafka, per copy.
- **Disk** = per-copy volume × retention × 3 replicas ÷ brokers × 2 (headroom for bursts and
  rebalancing). M: 250 GB × 1 day × 3 ÷ 3 × 2 ≈ **500 Gi per broker**. Retention can be
  raised as long as the disk follows.
- **Throughput** is small for Kafka. M peak: ~50 MB/s of OTLP → ~8 MB/s compressed in,
  ×3 for replication, and the same ~8 MB/s out to the gateways.
- **Partitions** ≥ gateway pods × 4, so the gateways stay balanced and a slow partition
  holds back few streams. Only ever increase them: existing streams then move to a new
  partition once, which can reorder a few records at that moment.
- Brokers run on the Loki node pools (`placement`), one per zone. At M they add about one
  D16ds_v5 node's worth of CPU and memory across the 3 zones.
- **Lag** (`KafkaConsumerLagHigh`): the gateways normally keep the lag near zero. Lag that
  grows while Loki is healthy means too few gateway pods or partitions.

## Rules of thumb behind the numbers

- **Ingesters**: memory grows with **active streams** (per replica, × RF3), not bytes.
  Budget ~40-60 KB per active stream replica, plus chunk buffers.
  M: 300 k streams × 3 replicas ÷ 6 ingesters = 150 k per ingester → 16 Gi.
  Keep each ingester below ~20-30 MB/s of incoming (replicated) data.
- **Distributors**: about 1 CPU per 10-20 MB/s of push traffic.
- **Queriers**: one CPU core scans roughly 100-300 MB/s of compressed chunks.
  Query speed ≈ bytes scanned ÷ (queriers × cores). Narrow label selectors
  matter more than hardware.
- **Storage**: compression ~8-10× on typical application logs.
  M: 1 TB/day raw ≈ 110 GB/day stored.

## Storage estimate (M profile, example tenant mix)

| Tier | Share of volume | Retention | Stored (compressed) |
|---|---|---|---|
| gold | 40 % | 396 d | 0.4 × 110 GB × 396 ≈ 17.4 TB |
| silver | 45 % | 90 d | 0.45 × 110 GB × 90 ≈ 4.5 TB |
| bronze | 15 % | 31 d | 0.15 × 110 GB × 31 ≈ 0.5 TB |
| **Total** | | | **≈ 22 TB** |

With the lifecycle rule (Cool after 30 d, Cold after 180 d), most of the gold volume
sits in Cold. GZRS roughly doubles the per-GB price of LRS. Check the bank's
agreement prices, and include read and transaction costs: queries over old data
pay per-GB read fees in Cool and Cold.

## Per-tenant limits

Tiers in [`tenants.yaml`](../tenants/tenants.yaml):

| | bronze | silver | gold |
|---|---|---|---|
| `ingestion_rate_mb` (burst) | 4 (8) | 10 (20) | 30 (60) |
| `max_global_streams_per_user` | 5 k | 15 k | 50 k |
| `per_stream_rate_limit` | 3 MB | 5 MB | 10 MB |
| retention | 31 d | 90 d | 396 d |
| `max_query_parallelism` | 32 | 64 | 128 |
| `max_queriers_per_tenant` | 4 | 8 | 12 |

The sum of all tenants' `ingestion_rate_mb` **may exceed** the cluster's
capacity: tenants rarely peak together. Keep the sum under ~3× the capacity, and
watch `loki_distributor_bytes_received_total` by tenant.

Per-tenant **write** isolation comes from rate and stream limits, and hot-stream sharding
(`shard_streams`). Loki 3.6 has no write-side shuffle sharding: each tenant's streams are
spread over all ingesters. Read-side isolation also comes from `max_queriers_per_tenant`.

## Scaling triggers

| Signal | Action |
|---|---|
| Ingester memory > 75 % or active streams per ingester > 200 k | add 1 ingester **per zone** (`ingester.replicas` += 3) |
| Distributor CPU > 70 % | the HPA handles it; raise `maxReplicas` if it sits at max |
| Scheduler queue length high, queries slow | raise querier `maxReplicas`; check `max_queriers_per_tenant` |
| Chunks-cache hit rate < 80 % | more memcached replicas or memory |
| Node pool at `max_count` | raise `loki_nodes_per_zone.max` (Terraform) |
| Kafka broker disk > 70 % | more disk (`kafka.brokers.storage`, expandable), or shorter `kafka.topic.retentionHours` |
| Kafka consumer lag growing while Loki is healthy | more gateway pods (steps of 3) and partitions |

## Load test before go-live

1. Generate synthetic logs at 1×, 3× and 5× the expected average, with a realistic
   label shape (`k6` with the xk6-loki extension, or `loki-canary`-style generators).
   Run them from a test namespace mapped to a test tenant.
2. Run the heaviest expected dashboards and a 7-day `|= "error"` search in parallel.
3. Kill an ingester, then a whole zone's node pool (cordon + drain), during the test.
4. Pass criteria: the SLOs in [04](04-reliability-and-dr.md#targets-proposal-agree-them-with-the-service-owners);
   no `LokiPushErrors`; zero `OtelDroppingLogs`; no queue above 50 %.

# ADR 0006 · No Kafka (or Event Hubs) in the log pipeline, for now

**Status:** superseded by [ADR 0010](0010-kafka-in-cluster.md) (2026-10-05): Kafka now runs in the cluster, between the collector tiers. Kept for the reasoning; `environments/overlays/no-kafka.yaml` still installs this design. · **Date:** 2026-09-28

## Context
A message bus in front of Loki can absorb bursts, survive long Loki outages, allow replay,
and fan logs out to other consumers. Reviewers will ask why the design has none.

## Decision
No bus. Durability comes from a disk-backed buffer at every hop:
1. kubelet log files;
2. the OTel agent's persistent queue on the node;
3. **a persistent queue per tenant** on the OTel gateway's zonal SSDs;
4. Loki's WAL with 3 replicas across zones;
5. GZRS storage.

Details and limits: docs/08.

## Revisit when
- Planned Loki downtime must regularly exceed what the gateway queues can hold.
- A second consumer (SIEM, data lake, fraud analytics) needs the same stream with replay.
- Loki's Kafka-based ingest (experimental in 3.6) is GA and the scale needs it.

## If revisited
Azure **Event Hubs** (Kafka endpoint, Premium or Dedicated, private endpoint, CMK, Entra
auth), placed **between the OTel agents and the OTel gateway**. It would use the collector's
own `kafka` exporter and receiver, which are already in the pinned contrib build. Only the
agents' identity may produce. Nothing else changes.

## Consequences
One fewer stateful platform to run, secure, evidence and pay for. A tenant throttled beyond
its gateway queue can delay other tenants on the same nodes (docs/08, "Limits"). This is
mitigated by alerting at 50 % queue use.

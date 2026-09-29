# ADR 0001 · Loki in distributed mode, ingesters zone-aware

**Status:** accepted · **Date:** 2026-09-28

## Context
The log backend must survive the loss of one availability zone without failing writes, and must
scale reads and writes independently. It serves many tenants with very different volumes.

## Decision
Run Loki 3.6 in **distributed** (microservices) mode with the `grafana/loki` chart:
- **zone-aware replication** (`ingester.zoneAwareReplication`): one ingester StatefulSet per zone,
  replication factor 3, so every stream has exactly one copy per zone;
- **rollout-operator** for zone-by-zone upgrades;
- **one AKS node pool per zone**, so the cluster autoscaler always adds capacity in the zone that
  needs it (ingester volumes are zonal disks).

## Alternatives
- **Single binary / monolithic**: too small; no independent scaling.
- **Simple Scalable (read/write/backend)**: simpler, but coarse scaling, and Grafana is moving
  away from it.
- **One pool across 3 zones**: the autoscaler can add a node in the wrong zone for a pending zonal
  PVC.

## Consequences
More components to operate (about 12 kinds of pods), mitigated by the chart and the runbook.
A zone loss costs a third of the capacity: size for N+1 zones (docs/05).

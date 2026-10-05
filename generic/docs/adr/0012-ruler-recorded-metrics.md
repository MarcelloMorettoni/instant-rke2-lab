# ADR 0012 · Loki ruler with recording rules, and a tenant-isolated metrics store

**Status:** accepted · **Date:** 2026-10-05

## Context
Index gateways already take the index work off the queriers: they hold each day's TSDB index
on local disk and serve it to every querier. Each querier no longer downloads and keeps its
own copy.

The other big read load is **repetition**:
- every dashboard panel that counts logs re-scans chunks on every refresh, for every viewer;
- every Grafana alert rule on LogQL runs a log query every minute, whether or not anyone is
  looking.

Both go through the query frontend into the **same per-tenant queues as people's queries**.
The results cache helps only for finished time splits; the current hour is scanned again on
every refresh.

The first design left the ruler off, because Loki's alerting rules need a multi-tenant
Alertmanager. That covered alerting, but not this load.

## Decision
**Run the Loki ruler for recording rules only, and keep the results in a small,
tenant-isolated metrics store.** The same in both installations (ADR 0011).

- **Ruler**: 2 replicas, rule groups sharded between them (ring).
  - **Local evaluation**: its own embedded querier reads ingesters, the index gateways and
    object storage. Rule load never waits in the users' queues.
  - A WAL on a PVC buffers results while the store is down.
- **Rules come from git.** `tenants.yaml` has a standard set for every Loki tenant:
  - `obs:log_lines:rate1m`, `obs:log_bytes:rate1m` and `obs:log_errors:rate1m`;
  - per namespace and service;
  - with a 30 s `offset`, so late-arriving lines are counted.

  Tenants add their own rules (`recordingRules:`) by pull request. `render-tenants.py`
  renders one ConfigMap per tenant (`loki.ruler.directories`). The ruler API is off.
- **Every result carries `tenant="<owner>"`.** The generator stamps it on every rule, last,
  over anything the rule says. A rule's LogQL only reads its own tenant's logs (the ruler
  runs it under that tenant's ID). So no rule can read or write another tenant's data.
- **Metrics store**: `obs-metrics`, a receive-only Prometheus (2 replicas, 400 d, 50 Gi). The
  ruler writes **every sample to both replicas**, so either one can serve reads.
- **Tenant guard**: `obs-metrics-proxy` (prom-label-proxy):
  - it adds `tenant=~"<X-Obs-Tenant>"` to every PromQL selector, replacing any `tenant`
    matcher the query had;
  - the read gateway **sets** that header from the view, exactly like `X-Scope-OrgID`:
    same view, same key, under `/<view>/prometheus/`;
  - no header is refused (400), and writes and admin paths don't exist (404, and 403 at
    the gateway).
- **Grafana**: grafana-sync gives each org a second data source, "Log metrics (recorded)".
  Tenants build dashboards and alerts on it, and use Loki for the lines themselves.
- **No alerting rules in the ruler**, so no Alertmanager. Grafana-managed alerts read the
  recorded series, which costs nothing on the log path.

## Why not
- **Managed Prometheus (Azure) for the recorded series**: it can't enforce tenants on read
  without a proxy that also handles Entra authentication. The generic installation has no
  Azure, and one design for both was the goal.
- **Mimir** (multi-tenant natively): a whole second distributed system for a few thousand
  small series.
- **Tenants editing rules through the ruler API**: unreviewed load (any LogQL, any interval)
  and a second write path into the platform. Revisit with per-tenant rule limits (already
  set: `ruler_max_rule_groups_per_tenant`, `ruler_max_rules_per_rule_group`) once self-service
  is wanted.

## Consequences
- **Plus**:
  - dashboards and alerts on log counts read Prometheus, not chunks;
  - 30-day trends cost points, not terabytes;
  - background load can't slow people's queries;
  - Cool/Cold storage reads drop.
- **Minus**: three more components to run (ruler, store, guard) and four alerts
  (`LokiRulerEvaluationFailures`, `LokiRulerMissedEvaluations`,
  `LokiRulerRemoteWriteBehind`, `MetricsStoreDown`).
- **Recorded series are derived data.** They lag by about 30 s (the offset) plus the interval.
  A replica that was down has a gap for that time, so reads may differ slightly between
  replicas. Logs remain the source of truth, and any series can be recomputed from Loki.
- **Verified**: `scripts/pipeline-test.sh` runs the rendered rules in Loki 3.6.11's ruler,
  writes to Prometheus and reads back through prom-label-proxy v0.15.1. It checks per-tenant
  series, the tenant's own rule, isolation between views, a two-tenant view, and refusal
  without a header.

# ADR 0008 · Caching on the read path only, with memcached

**Status:** accepted · **Date:** 2026-09-29

## Decision
- **Results cache**: memcached ×2 × 2 GB, entries valid 12 h. It caches query-slice results
  per tenant.
- **Chunks cache**: memcached ×3 × 8 GB, spread across zones. It caches chunks read from Blob.
- **Index gateways** keep the TSDB index on local disk (3 × 50 GiB).
- **No write-path cache**: the write path has durable queues instead (ADR 0006).
- **No L2 chunks cache and no Redis** for now.

## Why
- Memcached is Loki's tested cache, deployed by the chart.
- The caches need no persistence: every entry can be rebuilt from Blob.
- Losing a cache costs latency and some Blob read cost, never data or availability.
- Cache keys are per tenant, and only Loki pods can reach memcached.

## Revisit when
- The chunks-cache hit rate stays below ~80 %.
- Blob read costs grow from long-range queries: then turn on `chunksCache.l2`.
- The bank requires encryption in transit inside the cluster for cache traffic (WireGuard
  node encryption covers it).

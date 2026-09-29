# ADR 0003 · A read gateway with one view per Grafana org

**Status:** accepted · **Date:** 2026-09-28

## Context
Grafana must query Loki as the right tenant for each org, and nothing a user controls may change
that tenant.

## Decision
- A **kgateway** (Envoy, Gateway API) in front of the query frontend.
- One **view** (HTTPRoute + TrafficPolicy) per Grafana org, generated from the registry.
- Each view accepts only its own **API key** (in Key Vault → External Secrets), **sets**
  `X-Scope-OrgID` to the org's tenant list, and refuses push and delete.
- Each Grafana org has one Loki data source pointing at its view, with its key in `secureJsonData`.
- NetworkPolicies ensure only Grafana reaches the gateway, and only the gateway reaches the query
  frontend.

## Alternatives
- **Loki chart's nginx gateway with basic auth**: workable, but nginx's `proxy_set_header`
  inheritance makes header overwrite error-prone.
- **Forward the user's OAuth token and map claims to tenants**: breaks Grafana-managed alerting
  and other background queries.
- **Grafana Enterprise LBAC**: a licensed alternative.

## Consequences
One key per org to manage; `tenant-keys.sh` automates creation and rotation. The gateway access
log becomes the audit trail of reads.

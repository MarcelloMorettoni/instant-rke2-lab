# ADR 0009 · Grafana signs in with Entra ID directly; Keycloak is optional

**Status:** accepted · **Date:** 2026-09-29

## Context
Users need single sign-on to Grafana, and each user must land in the right tenant's org with
the right role. Keycloak (optionally brokering Entra ID) was considered.

## Decision
Grafana uses **Entra ID directly** (`auth.azuread`):
- Entra security groups map to Grafana orgs and roles (`org_mapping`, generated from
  `tenants.yaml`);
- only members of mapped groups can log in (`allowed_groups`);
- nobody gets Admin through sign-in.

No Keycloak.

## Why
- Entra ID already provides MFA, Conditional Access, PIM, lifecycle processes and sign-in
  audit. Keycloak in between adds a hop, not a capability.
- Keycloak would be another critical, stateful system: HA, database, patching, backup, and
  control evidence. It would sit in every login, so its outage would block all access to logs.
- Tokens don't carry the tenant in this design:
  - write path: the tenant comes from the namespace (ADR 0002);
  - read path: it comes from the read gateway's per-view keys (ADR 0003).

  So claim shaping, Keycloak's main added value, isn't needed.
- Tenants are internal teams in one Entra tenant, and they don't push logs with credentials.

## Revisit when
- Tenants include external organisations with their own identity providers.
- Users come from several Entra tenants, or from outside Entra.
- The bank's IAM standard becomes Keycloak.
- Tenants push logs with their own credentials (client-credentials flows).

## If revisited
Replace `grafana.grafana.ini.auth.azuread` with `auth.generic_oauth` pointed at the Keycloak
realm, with a `groups` claim; `org_mapping` works the same way (docs/02). The read gateway,
views, collectors and Loki don't change.

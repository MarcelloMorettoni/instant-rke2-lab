# ADR 0009 · Grafana signs in with Entra ID directly; Keycloak is a supported option

**Status:** accepted (revised 2026-09-29: the provider is a chart setting; 2026-10-05: the chart can install Keycloak, used by the generic profile, ADR 0011) · **Date:** 2026-09-29

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
The provider is a chart setting: `auth.provider: keycloak`, plus `auth.keycloak.url`, `realm`
and `clientId`, and the tenants' `groups.oidc` names in `tenants.yaml` (docs/02). `oidc`
covers other providers, and `disabled` gives mock users for test clusters. The read gateway,
views, collectors and Loki don't change.

## Since 2026-10-05: Keycloak installed by the charts
The **generic** profile (ADR 0011) has no Entra ID to rely on, so the charts can install
Keycloak (`keycloak.install: true`):
- the Keycloak operator comes with the operators chart;
- Keycloak itself (2 instances, PostgreSQL from Percona) is served on Grafana's internal
  load balancer;
- realm `obs` is imported once, with:
  - the `grafana` client, whose secret the chart generates and shares with Grafana;
  - one group per `tenants.yaml` `groups.oidc` name;
  - optional lab users;
  - optionally **Entra ID as identity provider** (`keycloak.realm.entraBroker`). Entra's
    group object IDs are then mapped to the realm groups, so MFA and Conditional Access
    stay in Entra.

The Azure profile keeps Entra ID directly, for the reasons above. The trade-off is now
visible in one switch.

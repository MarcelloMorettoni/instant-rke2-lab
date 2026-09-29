# 02 · Tenancy and access

**One rule behind every decision: a tenant never controls anything that sets
its own identity.** Tenants choose their pod labels, the headers they send and
the data sources they might create, so none of those are trusted. Tenants can't
change namespace names (cluster-scoped, platform RBAC), Entra ID group
membership (IAM process) or the gateway's config. Those are what the design trusts.

| Layer | Trusted identity | Enforced by |
|---|---|---|
| Logs (write) | namespace **name**: from the log file path, or from the OTLP sender's pod IP | OTel agent maps it to a tenant (`rendered/values-tenants.yaml`, `otelAgent`); claimed identities are deleted |
| OTel gateway | who can connect | NetworkPolicy: only the agents (ns `otel-agent`) |
| Loki (write) | who can connect | NetworkPolicy: only the OTel gateway (ns `otel`) reaches the distributors |
| Loki (read) | `X-Scope-OrgID` | set by the gateway view, never by the caller |
| Gateway view | per-view key | kgateway `apiKeyAuth`, key only in Key Vault → Grafana |
| Grafana org | Entra ID group object IDs | `org_mapping` + `allowed_groups` (generated) |
| Grafana data source | org membership | one data source per org, users never org Admin |

## The tenant registry

[`tenants/tenants.yaml`](../tenants/tenants.yaml) is the single source of truth.
[`scripts/render-tenants.py`](../scripts/render-tenants.py) turns it into everything tenant-specific:

```text
tenants.yaml ──► rendered/values-tenants.yaml   values for charts/log-platform:
                   otelAgent.alternateConfig      namespace regex → tenant (OTTL)
                   otelGateway.alternateConfig    one exporter + persistent queue per tenant
                   loki.loki.runtimeConfig        tier limits + retention per tenant
                   readViews                      → HTTPRoute + key policy + ExternalSecret per view
                   grafanaOrgs                    → orgs + data sources (grafana-sync CronJob)
                   grafanaOrgMapping              → Entra group → org + role, allowed groups
```

A tenant entry:

```yaml
- id: cards                      # Loki tenant ID and Grafana org name. Never rename.
  name: Cards
  tier: gold                     # bronze | silver | gold: limits + retention
  status: active                 # active | suspended | offboarding
  namespaces: cards(-.+)?        # RE2, full match: cards, cards-batch, cards-uat...
  alsoRead: [shared-services]    # optional: cross-tenant READ access
  limits: {ingestion_rate_mb: 40}  # optional: override one tier value
  entraGroups:
    viewer: <group object id>
    editor: <group object id>
```

### Special tenants

| Tenant | Contains | Who reads it |
|---|---|---|
| `platform` | AKS system namespaces, the observability stack itself, gateway access logs | Platform org only |
| `unassigned` | any namespace that matches no tenant | Platform org only; an alert fires ([07](07-tenant-onboarding.md#unassigned-namespaces)) |

`unassigned` exists so that a new namespace is **never silently dropped** and
**never lands in someone else's tenant**. It stays visible to the platform
until someone adds it to the registry.

### Namespace naming

The mapping trusts namespace **names**, so the platform must control who creates
namespaces and how they are named:
- **Namespace creation is a platform action**: GitOps, or a self-service portal that
  applies the naming rule. Tenants have no `create namespaces` RBAC.
- Recommended rule: `<tenant-id>-<purpose>`, e.g. `payments-prod`,
  `payments-batch`. The default regexes (`payments(-.+)?`) assume it.
- To be strict, add a `ValidatingAdmissionPolicy` that rejects a namespace whose name
  doesn't match its `tenant` label, as in the lab's
  [`01-namespaces/namespace-guard.yaml`](../../soft-tenancy/01-namespaces/namespace-guard.yaml).

## Access model in Grafana

- **Login**: Entra ID only (`[auth.azuread]`), PKCE, restricted to the bank's
  Entra tenant (`allowed_organizations`). Only members of a **mapped** group can
  log in (`allowed_groups`, generated).
- **Org and role**: from group membership (`org_mapping`, generated):
  `<viewer-group>:<tenant>:Viewer` and `<editor-group>:<tenant>:Editor`.
  A person in several tenants' groups is a member of several orgs and switches between them.
- **Nobody becomes org Admin or server admin through SSO**
  (`allow_assign_grafana_admin = false`). An org Admin can edit data sources. Even
  then they would need another view's key, which only Key Vault and the
  gateway have.
- **Main Org** (id 1) is where unmapped logins would land. It has no data
  sources, and the `grafana-sync` job warns if it ever gets one.
- **Break-glass**: the local `platform-breakglass` admin (password in Key Vault),
  used only over `kubectl port-forward`. Rotate the password after every use.

### Entra ID app registration

1. Create an app registration "Grafana observability" with redirect URI
   `https://grafana.obs.bank.internal/login/azuread`.
2. **Token configuration → groups claim → "Groups assigned to the application"**.
   This avoids the >200-group overage problem, where the token carries no groups at all.
3. **Enterprise application → Assignment required = Yes**, and assign every
   `sg-obs-*` group. Only assigned users can get a token.
4. Client secret or certificate → Key Vault secret `grafana-entra-client-secret`.
5. Put the application (client) ID and tenant ID in `environments/<env>/values.yaml` (`grafana.grafana.ini.auth.azuread`).

### Using Keycloak instead of (or in front of) Entra ID

If the bank brokers Entra ID through Keycloak, replace `[auth.azuread]` with
`[auth.generic_oauth]` pointed at the Keycloak realm, and emit a `groups` claim
(or a `tenant` claim) from Keycloak. `org_mapping` works the same way
([Grafana generic OAuth](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)).
Nothing else changes: the gateway keys, not the user's token, decide the tenant.

## Cross-tenant reading (`alsoRead`)

`cards` may read `shared-services`: its view sets
`X-Scope-OrgID: cards|shared-services`. Loki's multi-tenant query support
(`querier.multi_tenant_queries_enabled`) returns both. The data stays in
`shared-services`, and `shared-services` can't read `cards`. Grant it in the
registry through a reviewed change; it's a data-sharing decision, so record the
data owner's approval in the pull request.

## Platform access

The `platform` view reads `platform|unassigned|<every live tenant>`. It is
regenerated whenever a tenant is added. Access is the `sg-obs-platform-*` groups:
- **viewers**: e.g. service desk, read only;
- **editors**: SRE.

Every query through the gateway is in the gateway's access log (tenant list,
path, status; never the key). The access log goes to the `platform` tenant, so
the audit trail of who read which tenant is itself in Loki.

## Why not…

| Option | Why not here |
|---|---|
| Let apps push to Loki with their own tenant header | Any pod could write into (or flood) any tenant. The header is unauthenticated. |
| Loki chart's nginx gateway with basic auth per tenant | It works for writes. For reads it gives every tenant user a Loki credential, and header handling is harder to get right in nginx (`proxy_set_header` inheritance). |
| Grafana data source with "forward OAuth identity" | Background features (alerting, recording, reports) have no user token, so tenants' alerts would silently stop. |
| Grafana Enterprise / Cloud LBAC | A valid option if the bank licenses it. This design stays open source. |
| One Grafana per tenant | 200 Grafanas to patch; no single audit point. Orgs give the same isolation for this use. |

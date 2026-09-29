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
| Grafana org | identity-provider group (Entra object ID, or Keycloak/OIDC group name) | `org_mapping` + `allowed_groups` (generated per provider) |
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
  groups:                        # who signs in to this tenant's org, per identity provider
    entra: {viewer: <group object id>, editor: <group object id>}
    oidc:  {viewer: obs-cards-viewers, editor: obs-cards-editors}   # Keycloak / OIDC group names
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

## Sign-in to Grafana: `auth.provider`

One chart setting selects the identity provider:

| `auth.provider` | Sign-in | Users land in their org by | For |
|---|---|---|---|
| `entra` (default) | Microsoft Entra ID | Entra security groups: `groups.entra` (object IDs) | production |
| `keycloak` | Keycloak realm (OIDC) | the token's groups claim: `groups.oidc` (names) | banks with Keycloak as IAM, or brokering several IdPs |
| `oidc` | any other OIDC provider, with explicit endpoints | the groups claim: `groups.oidc` | other IdPs |
| `disabled` | **mock**: no identity provider, local users | fixed users (`auth.mock`) | **test clusters only** |

The chart turns `auth:` into ConfigMap `grafana/grafana-auth` (Grafana's `GF_AUTH_*`
settings) and adds the client secret to `grafana-env` from Key Vault. `install.sh` restarts
Grafana when those settings change.

Whatever the provider, the rules stay the same:
- **Only members of a mapped group can log in** (`allowed_groups`).
- **The org and role come from group membership** (`org_mapping`, generated from `tenants.yaml`).
- **Nobody becomes Grafana server admin through sign-in.** Tenant users are Viewer or Editor,
  never org Admin: an Admin could add a data source, but would still need another view's key.
- **Main Org** (id 1) has no data sources, so a stray login sees nothing. `grafana-sync`
  warns if Main Org ever gets a data source.
- **The tenant is never taken from the token**: the read gateway's per-view key decides it.
  Switching providers doesn't change the isolation.
- **A local admin exists in every mode**: `admin`, initial password **`change-me-now`**
  (`auth.admin`).
  - It signs in with the password form at `/login?disableAutoLogin=true`; normal users are
    sent straight to SSO.
  - It is Grafana server admin, and Admin of the platform org, which reads every tenant.
  - `grafana-sync` creates it once and **never resets its password**. Change the password at
    first login; it stays changed.
  - **Until it's changed, anyone who can reach Grafana can sign in as server admin.** The chart
    NOTES and `smoke-test.sh` warn while the default is still active.
  - `auth.admin.fromKeyVault: true` takes the initial password from Key Vault
    (`grafana-admin-password`) instead.
  - `auth.localLogin: false` hides the form (the admin can then only use the API).
- **Automation account**: `grafana-sync` signs in as its own account, Grafana's built-in admin
  `grafana-sync`, whose random password is in Secret `grafana-admin`. Changing the human
  admin's password therefore never breaks the sync.

### Entra ID (`auth.provider: entra`)

```yaml
auth:
  provider: entra
  entra:
    tenantId: <directory (tenant) ID>
    clientId: <application (client) ID>
```

1. Create an app registration "Grafana observability" with redirect URI
   `https://<grafana host>/login/azuread`.
2. **Token configuration → groups claim → "Groups assigned to the application"**. This avoids
   the >200-group overage problem, where the token carries no groups at all.
3. **Enterprise application → Assignment required = Yes**, and assign every `sg-obs-*` group.
4. Store the client secret (or use a certificate) in Key Vault as `grafana-entra-client-secret`,
   or the name set in `auth.clientSecretKeyVaultName`.
5. Put the groups' object IDs into `tenants.yaml` under `groups.entra`.

### Keycloak (`auth.provider: keycloak`)

```yaml
auth:
  provider: keycloak
  keycloak:
    url: https://sso.bank.internal      # without /realms
    realm: bank
    clientId: grafana
network:
  identityProviderCidrs: [10.30.4.0/24]  # if Keycloak has a private address
```

1. In the realm, create client `grafana`:
   - OpenID Connect, client authentication ON;
   - standard flow only;
   - PKCE S256;
   - valid redirect URI `https://<grafana host>/login/generic_oauth`;
   - valid post-logout redirect URI `https://<grafana host>/login`.
2. Add a **"Group Membership" mapper** to the client: token claim name `groups`, **"Full group
   path" OFF**, added to the ID token, access token and userinfo.
3. Create one group per tenant and role (`obs-payments-viewers`, `obs-payments-editors`, ...),
   and put the names into `tenants.yaml` under `groups.oidc`.
4. Store the client secret in Key Vault as `grafana-oidc-client-secret`.

If Keycloak brokers Entra ID, users still come from Entra, but Grafana sees Keycloak's groups.
Map Entra groups to Keycloak groups in the identity provider's mappers.

The chart derives the auth, token, userinfo and logout endpoints from `url` + `realm`. If
Keycloak's certificate comes from the bank's internal CA, mount the CA into Grafana
(`grafana.extraConfigmapMounts`) and set `grafana.grafana.ini.auth.generic_oauth.tls_client_ca`
to its path.

### Other OIDC providers (`auth.provider: oidc`)

Same as Keycloak, with explicit endpoints: `auth.oidc.clientId`, `authUrl`, `tokenUrl`,
`apiUrl` (userinfo) and, optionally, `signoutRedirectUrl`. If the provider names claims
differently, set `auth.claims.groups`, `login`, `email` and `name` (JMESPath).

### Mock (`auth.provider: disabled`): test clusters only

No identity provider at all. The chart creates local users; `grafana-sync` makes each one a
member of **exactly** its org:

| Login | Initial password | Org | Role |
|---|---|---|---|
| `alice` | `change-me-now` | payments | Editor |
| `bob` | `change-me-now` | cards | Editor |
| `carol` | `change-me-now` | lending | Editor |
| `admin` | `change-me-now` | platform (reads every tenant) | Admin; also Grafana server admin |

- Passwords are **initial** passwords: set when `grafana-sync` creates the user, never reset.
  Each person changes theirs in Grafana (profile → change password).
- `auth.mock.password: ""` gives each mock user a random password instead, kept in Secret
  `grafana/grafana-local-users`:
  ```bash
  kubectl -n grafana get secret grafana-local-users -o jsonpath='{.data.alice}' | base64 -d
  ```
- Change the users in `auth.mock.users`. The chart refuses a user whose org isn't an active
  tenant.
- Everything else stays real: the read gateway, the per-view keys, and the network isolation.
  A mock user can only read its tenant's logs.

**Never use `disabled` in production:** the passwords live in the cluster, and there is no
MFA or central user lifecycle.

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

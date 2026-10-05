# 07 · Tenant onboarding and lifecycle

Every change is a pull request to [`tenants/tenants.yaml`](../tenants/tenants.yaml)
together with the regenerated `rendered/` folder. Nothing is done by hand in the
cluster, and no change needs Terraform.

## Onboard a tenant

**Inputs from the requesting team**:
- tenant ID;
- namespaces (or the naming prefix);
- tier;
- data owner;
- two groups (viewers, editors) in the bank's identity provider, created through the IAM
  process: Entra ID object IDs (`groups.entra`), and/or Keycloak/OIDC group names (`groups.oidc`).

1. Add the entry:
   ```yaml
   - id: treasury
     name: Treasury
     tier: silver
     status: active
     namespaces: treasury(-.+)?
     groups:
       entra:
         viewer: <object id of sg-obs-treasury-viewers>
         editor: <object id of sg-obs-treasury-editors>
       oidc:                                       # if a cluster uses Keycloak / OIDC
         viewer: obs-treasury-viewers
         editor: obs-treasury-editors
   ```
2. Check the mapping, then render:
   ```bash
   scripts/render-tenants.py --which treasury-prod treasury-batch payments-prod
   scripts/render-tenants.py
   scripts/validate.sh
   ```
3. **Entra ID**: in the enterprise app "Grafana observability", **assign both groups**, or the
   group claim won't carry them. **Keycloak** (your own, or the one `keycloak.install` installs):
   create the two groups in the realm (`obs` when installed), with exactly the `groups.oidc`
   names. The installed realm is imported once, so new groups are never added by the chart
   ([06](06-operations-runbook.md#keycloak-generic-installation)). If Keycloak brokers Entra
   ID, also add an "Advanced Claim to Group" mapper on the `entra` identity provider: claim
   `groups` = the Entra object ID → the new group.
4. Open the pull request. The reviewer checks:
   - the regex doesn't overlap another tenant (`--which`);
   - the tier matches what was agreed;
   - any `alsoRead` has the data owner's approval.
5. After merge:
   ```bash
   scripts/install.sh <env> 20    # key in Key Vault, then the chart, then grafana-sync
   ```
   Step 20 creates the view's key in Key Vault (generic: the chart generates it at step 30). Step 30 upgrades the chart: agent mapping,
   gateway exporter and queue, Loki overrides, read view, and org mapping (Grafana restarts
   if that changed). Step 40 runs grafana-sync now instead of at its next schedule.
6. Tell the team: "Sign in at https://grafana.obs.bank.internal. Your logs are in the
   *treasury* org, data source *Loki*."

A tenant's logs flow from the moment its namespace exists and the OTel agents have the new
mapping. Logs written **before** the mapping existed went to `unassigned`, and stay
there. They are not moved.

## Change a tenant

| Change | Edit | Takes effect |
|---|---|---|
| Tier or one limit | `tier:` or `limits:` | step 30 (chart upgrade): runtime config, reloaded in seconds |
| Retention | `tier:` or `limits.retention_period` | next compactor run. **Shortening deletes data** |
| Add a namespace pattern | `namespaces:` | step 30 (chart upgrade): the collectors roll out |
| Cross-tenant read | `alsoRead:` | step 30 (chart upgrade): the view's header changes |
| Groups | `groups:` | step 30 (chart upgrade): Grafana restarts, users re-map at next login |

## Suspend a tenant

`status: suspended`. Logs are still collected and kept, but **nobody reads through
the tenant's view**: the view and its key are removed. The platform org can still
read the logs. Use this for security incidents or disputes.

## Offboard a tenant

1. `status: offboarding`. The view is removed, and retention is forced to **24 h**.
2. Deploy. Within about a day, the compactor deletes the tenant's data.
3. Once `loki_distributor_lines_received_total{tenant="<id>"}` stays at zero and the data is
   gone, remove the entry. Then delete its Grafana org (Administration → Organizations, as the
   local `admin`): grafana-sync never deletes orgs. That also deletes the org
   and its dashboards.
4. Delete the Key Vault secret `obs-key-<id>`, and remove the groups from the enterprise app.

If a legal hold applies, **don't** offboard: suspend instead, and set the retention
explicitly.

## Unassigned namespaces

`LokiUnassignedNamespaceLogging` means a namespace that matches no tenant is
sending logs. They land in the `unassigned` tenant, which only the platform org can read.

1. In the platform org, find the namespace with the query:
   ```logql
   sum by (namespace) (count_over_time({cluster=~".+"}[1h]))
   ```
   Run it with the data source's tenant list, which includes `unassigned`.
2. Either extend a tenant's `namespaces:` regex, or add a new tenant.
3. If the namespace is platform tooling, add it to `platform.namespaces`.

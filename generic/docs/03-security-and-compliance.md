# 03 · Security and compliance

What the log platform does to protect the data, and how that maps to what a
bank's control framework usually asks. **Map it to your own framework**
(internal ICT policy, DORA, EBA ICT guidelines, PCI DSS, ISO 27001, local
regulator). This page lists the controls, not a certification.

## Controls by layer

### Identity and secrets

| Control | How |
|---|---|
| No static credentials for Azure | Loki → Blob and ESO → Key Vault use **Entra Workload Identity** (federated tokens, ~1 h, no keys, no client secrets) |
| Storage account keys disabled | `shared_access_key_enabled = false`; SAS tokens impossible |
| Least privilege | Loki's identity has *Storage Blob Data Contributor* on **one** storage account; ESO's has *Key Vault Secrets User* on **one** vault |
| Secrets never in git or Helm values | Key Vault → External Secrets → Kubernetes Secrets; gateway keys are generated straight into Key Vault (`scripts/tenant-keys.sh`) |
| Human access | Entra ID SSO with the bank's Conditional Access/MFA; no local users except one break-glass admin |
| Kubernetes API | Loki and Grafana pods don't mount a ServiceAccount token; the OTel agent can only read pods, namespaces and ReplicaSets; the OTel gateway mounts no token |

### Network

| Control | How |
|---|---|
| No public endpoints | Blob and Key Vault: public access disabled, private endpoints only. PostgreSQL: VNet-integrated. Grafana: internal load balancer |
| Default deny | `loki`, `otel`, `otel-agent`, `grafana` namespaces deny everything, then allow the flows below ([policies](../charts/log-platform/templates/)) |
| Write path | tenant pods → their node's OTel agent only; agents → OTel gateway only; gateway → distributor :3100 only (optional L7: `POST /otlp/v1/logs` only, with ACNS) |
| Read path | only the gateway → query-frontend; only Grafana → gateway |
| Tenants | no tenant namespace can open a connection into `loki` or `grafana` |
| Egress | Entra ID + Blob only; FQDN-restricted by the hub firewall, or in-cluster by `cilium-fqdn.yaml` with ACNS |
| In transit | TLS to Blob/Key Vault/PostgreSQL/Entra; HTTPS to Grafana. Pod-to-pod traffic inside the cluster is plain HTTP/gRPC. If the policy requires encryption in transit **inside** the cluster, enable WireGuard node-to-node encryption (Azure CNI Cilium/ACNS) or the AKS Istio add-on (mTLS) |

### Data at rest

| Data | Encryption |
|---|---|
| Chunks + index (Blob) | CMK (RSA-HSM 3072, Key Vault premium, auto-rotation) + infrastructure (double) encryption |
| Ingester WAL, compactor, index-gateway disks | CMK via disk encryption set (`EncryptionAtRestWithPlatformAndCustomerKeys`) |
| Node OS/temp disks | encryption at host (`host_encryption_enabled`) |
| Grafana database | PostgreSQL service encryption; data-source keys additionally encrypted by Grafana (`secureJsonData`) |
| Key deletion protection | Key Vault purge protection + 90-day soft delete. **A purged CMK makes all logs unreadable, forever.** |

### Data minimisation: what never gets stored

The OTel agents mask, before anything leaves the node, in log bodies **and** attributes
(`collector/agent-config.yaml`, `transform/mask`; tested end to end by `scripts/pipeline-test.sh`):

| Pattern | Example in | Stored as |
|---|---|---|
| Card numbers (PAN), 13-16 digits starting 3-6 | `card=4111111111111111` | `card=************1111` |
| IBAN | `DE89370400440532013000` | `DE89****3000` |
| Bearer / Basic authorization values | `Authorization: Bearer eyJ...` | `Authorization: Bearer <redacted>` |

These patterns are a **safety net, not a guarantee**. PCI DSS requires
that PAN is never logged in the first place: that's the application teams'
responsibility and should be part of their secure development checks. Extend the
patterns with the bank's own identifiers (customer numbers, national IDs),
and test each one against real log samples to avoid masking non-sensitive
numbers. `docs/06` shows how to test a pattern.

### Integrity and audit

| What | Where |
|---|---|
| Who read which tenant | gateway access log → `platform` tenant (tenant list, path, status, bytes) |
| Grafana logins and changes | Grafana server log → `platform` tenant; Entra ID sign-in logs |
| Access to the storage account | diagnostic settings → Log Analytics (`StorageRead/Write/Delete`) |
| Key Vault access | diagnostic settings → Log Analytics (`AuditEvent`) |
| Database | diagnostic settings → Log Analytics |
| Configuration changes | git history of this folder (`tenants.yaml`, values, policies) + AKS audit logs |

## Retention and regulatory records

- Retention is **per tenant**, from its tier: bronze 31 d, silver 90 d, gold 396 d.
  The compactor deletes older data; the Blob lifecycle rule deletes anything
  missed 30 days after the longest retention (safety net).
- PCI DSS 10.5.1 asks for **12 months of audit log history, 3 months
  immediately available**. The gold tier (396 d, all online) meets both. Cool and Cold
  are online tiers, and Loki reads them without restores.
- **Loki is not a WORM archive.** Retention and the delete API must be able to
  remove data, so the storage account has no immutability policy. If a record
  must be tamper-proof for N years (e.g. regulatory audit trails), send those
  streams **additionally** to an immutable store. For example, add a second
  exporter in the OTel gateway for the `audit-*` namespaces, sending to a
  separate storage account with a time-based immutability policy, or to the
  SIEM. Don't put an immutability policy on Loki's own containers: the compactor
  would fail.
- **GDPR / data-subject deletion**: Loki's delete API
  (`deletion_mode: filter-and-delete`) is **not** exposed through the gateway.
  The platform team runs it on request ([runbook](06-operations-runbook.md#deletion-requests)).

## Loki-specific hardening in this design

- `auth_enabled: true`: every request must name a tenant; there is no default tenant.
- Rules sidecar **off**. It would watch ConfigMaps in every namespace and needs
  a ClusterRole that reads every Secret.
- Ruler **off**: tenants alert with Grafana-managed alerts in their own org, so
  there's no multi-tenant Alertmanager to secure.
- `analytics.reporting_enabled: false`, the collectors export only to Loki, Grafana
  update checks off: no phone-home.
- Loki's own log level is `warn`, so Loki's logs don't echo tenants' log lines.
- Images come from the bank's ACR mirror (`global.imageRegistry`), where they can be
  scanned and signed before use.

## Residual risks (accepted, or to decide)

| Risk | Note |
|---|---|
| Platform admins can read everything | By design (the platform view, and cluster-admin). Control with PIM for AKS admin roles, and audit the gateway log. |
| **Default local admin password** | `admin` / `change-me-now` exists in every mode (`auth.admin`). Until someone changes it, anyone who can reach Grafana's internal load balancer can sign in as server admin. Change it at first login, and keep `network.grafanaClientCidrs` narrow. For production, use `auth.admin.fromKeyVault: true` or `auth.localLogin: false`. NOTES and the smoke test warn while the default is still active. |
| Shared nodes | Loki runs on dedicated tainted pools; tenants' pods share nodes with the OTel agent only. Soft tenancy: see the lab's "limits" section. |
| Masking misses a format | Defence in depth only; the application must not log secrets. |
| In-cluster traffic unencrypted | Decide per policy; see "In transit" above. |
| One Loki for all environments | If prod and non-prod share a cluster, consider separate tenants per environment (`payments-prod` vs `payments-uat` as two tenants) so access can differ. |

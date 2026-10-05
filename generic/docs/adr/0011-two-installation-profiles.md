# ADR 0011 · One Loki backend, two installation profiles: generic and Azure

**Status:** accepted · **Date:** 2026-10-05

## Context
The platform team needs to validate the **Loki backend architecture** itself. Some clusters
will have Azure services around them and some won't, and the team wants to show both. The
first design assumed Azure everywhere:
- Blob Storage;
- Key Vault with External Secrets;
- Azure Database for PostgreSQL;
- Entra ID;
- managed Prometheus.

## Decision
The charts install the same backend in both profiles. Only the services *around* it are
switches ([10 · Installations](../10-installations.md), pictures 08 and 09):

| Switch | Generic (`environments/generic`) | Azure (`environments/azure`) |
|---|---|---|
| `keyVault.enabled` | `false`: the chart generates the secrets | `true`: Key Vault + External Secrets |
| `postgres.provider` | `percona`: the Percona operator, brought by the team | `azure`: flexible server (Terraform) |
| `keycloak.install` + `auth.provider` | `true` + `keycloak` | `false` + `entra` |
| `monitoring` | `prometheusOperator.enabled` | `azurePodMonitors` |
| Loki storage | Azure Blob for now; `overlays/s3-storage.yaml` for any S3 API | Azure Blob (GZRS, Workload Identity, CMK) |

Unchanged in both profiles:
- Kafka (ADR 0010);
- the OTel agents and gateways;
- Loki (distributed, zone-aware);
- memcached;
- the read gateway;
- Grafana's org-per-tenant model;
- the NetworkPolicies;
- `tenants.yaml`.

`scripts/render-manifests.sh` writes both profiles as plain YAML, one file per component
(`manifests/azure/`, `manifests/generic/`), for review.

## Consequences
- One chart pair to test. `scripts/validate.sh` renders and checks both profiles, plus the
  test-cluster, no-Kafka and S3 variants.
- In the generic profile, the platform team owns more: Keycloak, PostgreSQL (with Percona),
  the Prometheus stack, and generated secrets instead of Key Vault's audit trail and rotation.
- Without Key Vault, the CMKs for storage and disks are not part of the chart. In the generic
  profile, disk and object-storage encryption are the cluster's and the store's.

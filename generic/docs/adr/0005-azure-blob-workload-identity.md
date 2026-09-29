# ADR 0005 · Azure Blob (GZRS) with Workload Identity and customer-managed keys

**Status:** accepted · **Date:** 2026-09-28

## Decision
- One StorageV2 account, **GZRS**: synchronous copies in 3 zones plus an async copy to the paired
  region.
- **Private endpoint only**, public access disabled, **shared keys disabled**.
- Loki authenticates with **Entra Workload Identity** (`use_federated_token`): a user-assigned
  identity with *Storage Blob Data Contributor* on this account only.
- **CMK** (RSA-HSM, Key Vault premium, automatic rotation) plus infrastructure encryption.
- Lifecycle: Cool after 30 d, Cold after 180 d, never Archive (Loki can't read offline blobs).
  Delete as a safety net after the longest retention + 30 d.

## Alternatives
- **Account key / SAS**: a long-lived secret that must be rotated and could leak.
- **ZRS**: use it instead of GZRS if the data may not leave the region (data residency). DR then
  needs dual-write (docs/04, tier B).
- **Immutable (WORM) containers**: incompatible with retention and deletes. Use a separate
  immutable store for records that need it (docs/03).

## Consequences
Terraform must run where it can reach the private Key Vault. A purged CMK makes all logs
unreadable: purge protection is mandatory.

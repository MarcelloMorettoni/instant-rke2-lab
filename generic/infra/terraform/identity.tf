# Workload Identity: Kubernetes ServiceAccount token → Entra ID token.
# No storage keys, no client secrets in the cluster.

# Loki (every component uses ServiceAccount loki/loki): read/write Blob.
resource "azurerm_user_assigned_identity" "loki" {
  name                = "id-loki-${local.suffix}"
  location            = azurerm_resource_group.obs.location
  resource_group_name = azurerm_resource_group.obs.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "loki" {
  name      = "aks-loki-sa"
  parent_id = azurerm_user_assigned_identity.loki.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = data.azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject   = "system:serviceaccount:loki:loki"
}

# Scoped to the storage account (not the resource group or subscription).
resource "azurerm_role_assignment" "loki_blob" {
  scope                = azurerm_storage_account.loki.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.loki.principal_id
}

# External Secrets Operator: read secrets from the observability Key Vault only.
resource "azurerm_user_assigned_identity" "eso" {
  name                = "id-eso-obs-${local.suffix}"
  location            = azurerm_resource_group.obs.location
  resource_group_name = azurerm_resource_group.obs.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "eso" {
  name      = "aks-external-secrets-sa"
  parent_id = azurerm_user_assigned_identity.eso.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = data.azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject   = "system:serviceaccount:external-secrets:external-secrets"
}

resource "azurerm_role_assignment" "eso_kv" {
  scope                = azurerm_key_vault.obs.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

# The storage account unwraps its CMK with this identity.
resource "azurerm_user_assigned_identity" "storage_cmk" {
  name                = "id-st-loki-cmk-${local.suffix}"
  location            = azurerm_resource_group.obs.location
  resource_group_name = azurerm_resource_group.obs.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "storage_cmk" {
  scope                = azurerm_key_vault.obs.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.storage_cmk.principal_id
}

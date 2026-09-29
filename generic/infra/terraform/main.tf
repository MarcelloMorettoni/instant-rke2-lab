# Azure resources behind the log platform:
#   storage.tf    Blob storage for chunks + index (GZRS, CMK, private endpoint, lifecycle)
#   keyvault.tf   Key Vault: CMKs, platform secrets, per-view gateway keys
#   identity.tf   managed identities + federated credentials (Workload Identity)
#   nodepools.tf  one Loki node pool per availability zone
#   postgres.tf   Grafana's database (zone-redundant HA)
#   alerts.tf     alerts/loki-alerts.yaml → managed Prometheus rule groups
#   diagnostics.tf audit logs of the storage account and Key Vault

data "azurerm_client_config" "current" {}

data "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_name
  resource_group_name = var.aks_resource_group_name
}

locals {
  suffix = "${var.environment}-${var.location_short}"
  tags = merge(var.tags, {
    workload    = "observability-logs"
    environment = var.environment
    managed-by  = "terraform"
  })
}

resource "azurerm_resource_group" "obs" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# Workload Identity needs the cluster's OIDC issuer.
check "aks_workload_identity" {
  assert {
    condition     = data.azurerm_kubernetes_cluster.aks.oidc_issuer_enabled && data.azurerm_kubernetes_cluster.aks.oidc_issuer_url != ""
    error_message = "Enable the OIDC issuer and Workload Identity on ${var.aks_name} first (az aks update --enable-oidc-issuer --enable-workload-identity)."
  }
}

# Offline plan test: mocked providers, no Azure credentials needed.
#   terraform -chdir=infra/terraform test
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_data "azurerm_kubernetes_cluster" {
    defaults = {
      id                  = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/aks-test"
      name                = "aks-test"
      oidc_issuer_enabled = true
      oidc_issuer_url     = "https://westeurope.oic.prod-aks.azure.com/tenant/issuer/"
      identity            = [{ type = "SystemAssigned", principal_id = "00000000-0000-0000-0000-000000000003", tenant_id = "t", identity_ids = [] }]
    }
  }
}
mock_provider "random" {}

variables {
  environment                = "test"
  location                   = "westeurope"
  location_short             = "weu"
  resource_group_name        = "rg-obs-test"
  aks_name                   = "aks-test"
  aks_resource_group_name    = "rg-aks"
  node_subnet_id             = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/nodes"
  private_endpoint_subnet_id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/pe"
  postgres_subnet_id         = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/pg"
  private_dns_zone_ids = {
    blob     = "/subscriptions/s/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    vault    = "/subscriptions/s/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    postgres = "/subscriptions/s/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/x.private.postgres.database.azure.com"
  }
  log_analytics_workspace_id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
  azure_monitor_workspace_id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Monitor/accounts/amw"
  action_group_id            = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Insights/actionGroups/ag"
}

run "plan" {
  command = plan

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.loki) == 3
    error_message = "expected one Loki node pool per zone"
  }
  assert {
    condition     = alltrue([for z, p in azurerm_kubernetes_cluster_node_pool.loki : p.zones == toset([z])])
    error_message = "each Loki node pool must be pinned to exactly its own zone"
  }
  assert {
    condition     = azurerm_storage_account.loki.shared_access_key_enabled == false && azurerm_storage_account.loki.public_network_access_enabled == false
    error_message = "storage must have no shared keys and no public access"
  }
  assert {
    condition     = length(azurerm_monitor_alert_prometheus_rule_group.loki) == 7
    error_message = "every group in loki-alerts.yaml must become a rule group"
  }
  assert {
    condition     = azurerm_federated_identity_credential.loki.subject == "system:serviceaccount:loki:loki"
    error_message = "Loki's federated credential must match the chart's ServiceAccount"
  }
}

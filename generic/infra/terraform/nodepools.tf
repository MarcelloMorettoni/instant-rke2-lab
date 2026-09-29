# One node pool PER ZONE. Ingester volumes are zonal disks: with one pool
# spanning 3 zones the autoscaler can add a node in the wrong zone and a
# pending ingester never schedules. Per-zone pools scale the right zone.
resource "azurerm_disk_encryption_set" "loki" {
  name                      = "des-loki-${local.suffix}"
  location                  = azurerm_resource_group.obs.location
  resource_group_name       = azurerm_resource_group.obs.name
  key_vault_key_id          = azurerm_key_vault_key.disks.versionless_id
  auto_key_rotation_enabled = true
  encryption_type           = "EncryptionAtRestWithPlatformAndCustomerKeys"
  identity {
    type = "SystemAssigned"
  }
  tags = local.tags
}

resource "azurerm_role_assignment" "des_kv" {
  scope                = azurerm_key_vault.obs.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.loki.identity[0].principal_id
}

# The Azure Disk CSI driver creates disks with this DES on the cluster's behalf.
resource "azurerm_role_assignment" "aks_des_reader" {
  scope                = azurerm_disk_encryption_set.loki.id
  role_definition_name = "Reader"
  principal_id         = data.azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

resource "azurerm_kubernetes_cluster_node_pool" "loki" {
  for_each                = toset(["1", "2", "3"])
  name                    = "loki${each.key}"
  kubernetes_cluster_id   = data.azurerm_kubernetes_cluster.aks.id
  mode                    = "User"
  vm_size                 = var.loki_vm_size
  zones                   = [each.key]
  vnet_subnet_id          = var.node_subnet_id
  os_sku                  = "AzureLinux"
  os_disk_type            = "Ephemeral"
  os_disk_size_gb         = 128
  host_encryption_enabled = true
  max_pods                = 60
  auto_scaling_enabled    = true
  min_count               = var.loki_nodes_per_zone.min
  max_count               = var.loki_nodes_per_zone.max

  node_labels = {
    "obs.platform/pool" = "loki"
  }
  node_taints = ["obs.platform/dedicated=loki:NoSchedule"]

  upgrade_settings {
    max_surge                     = "1" # one node at a time: never two ingesters of a zone down
    drain_timeout_in_minutes      = 30  # ingesters flush for up to 10 min (terminationGracePeriodSeconds)
    node_soak_duration_in_minutes = 5
  }

  tags = local.tags
  lifecycle {
    ignore_changes = [node_count] # the autoscaler owns it
  }
}

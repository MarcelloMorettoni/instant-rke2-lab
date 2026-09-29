# Loki's object store. Everything Loki has ever accepted lives here; the
# ingesters only hold the last ~2 hours.
#   - GZRS: synchronous copies in 3 zones + async copy to the paired region.
#   - No shared keys, no public network, TLS 1.2+, CMK with infrastructure
#     (double) encryption.
#   - Soft delete: 14 days to undo an accidental delete (not a backup of
#     retention deletes: the compactor's deletes are intended).
resource "random_string" "st" {
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_storage_account" "loki" {
  name                              = "stloki${var.environment}${var.location_short}${random_string.st.result}"
  location                          = azurerm_resource_group.obs.location
  resource_group_name               = azurerm_resource_group.obs.name
  account_kind                      = "StorageV2"
  account_tier                      = "Standard"
  account_replication_type          = var.storage_replication
  access_tier                       = "Hot"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  public_network_access_enabled     = false
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  infrastructure_encryption_enabled = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.storage_cmk.id]
  }

  customer_managed_key {
    key_vault_key_id          = azurerm_key_vault_key.storage.versionless_id # follows key rotation
    user_assigned_identity_id = azurerm_user_assigned_identity.storage_cmk.id
  }

  blob_properties {
    delete_retention_policy {
      days = 14
    }
    container_delete_retention_policy {
      days = 14
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags       = local.tags
  depends_on = [azurerm_role_assignment.storage_cmk]
}

resource "azurerm_storage_container" "loki" {
  for_each              = toset(["loki-chunks", "loki-ruler", "loki-admin"])
  name                  = each.key
  storage_account_id    = azurerm_storage_account.loki.id
  container_access_type = "private"
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-st-loki-${local.suffix}"
  location            = azurerm_resource_group.obs.location
  resource_group_name = azurerm_resource_group.obs.name
  subnet_id           = var.private_endpoint_subnet_id
  private_service_connection {
    name                           = "st-loki-blob"
    private_connection_resource_id = azurerm_storage_account.loki.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids.blob]
  }
  tags = local.tags
}

# Cheaper tiers for old chunks. Loki reads Cool and Cold transparently (they
# are online tiers). NEVER add an Archive rule: archived blobs are offline and
# every query touching them fails. The delete rule is a safety net: the
# compactor deletes per-tenant retention long before it.
resource "azurerm_storage_management_policy" "loki" {
  storage_account_id = azurerm_storage_account.loki.id

  rule {
    name    = "loki-chunks-tiering"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["loki-chunks/"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = var.cool_after_days
        tier_to_cold_after_days_since_modification_greater_than = var.cold_after_days
        delete_after_days_since_modification_greater_than       = var.max_retention_days + 30
      }
    }
  }
}

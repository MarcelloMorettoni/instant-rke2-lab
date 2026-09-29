# One Key Vault for the log platform. RBAC-authorised, private endpoint only,
# purge protection on (a deleted CMK would make every log chunk unreadable).
# Terraform must run from a network that reaches the private endpoint
# (self-hosted agent in the hub/spoke) to create keys and secrets.
resource "azurerm_key_vault" "obs" {
  name                          = "kv-obs-${local.suffix}"
  location                      = azurerm_resource_group.obs.location
  resource_group_name           = azurerm_resource_group.obs.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "premium" # HSM-backed keys
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
  tags = local.tags
}

resource "azurerm_private_endpoint" "vault" {
  name                = "pe-kv-obs-${local.suffix}"
  location            = azurerm_resource_group.obs.location
  resource_group_name = azurerm_resource_group.obs.name
  subnet_id           = var.private_endpoint_subnet_id
  private_service_connection {
    name                           = "kv-obs"
    private_connection_resource_id = azurerm_key_vault.obs.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids.vault]
  }
  tags = local.tags
}

# Whoever runs Terraform manages keys and secrets.
resource "azurerm_role_assignment" "deployer_kv_admin" {
  scope                = azurerm_key_vault.obs.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Customer-managed keys: one for Blob, one for the ingesters' managed disks.
resource "azurerm_key_vault_key" "storage" {
  name         = "cmk-loki-storage"
  key_vault_id = azurerm_key_vault.obs.id
  key_type     = "RSA-HSM"
  key_size     = 3072
  key_opts     = ["wrapKey", "unwrapKey"]
  rotation_policy {
    expire_after         = "P2Y"
    notify_before_expiry = "P30D"
    automatic {
      time_before_expiry = "P60D"
    }
  }
  depends_on = [azurerm_role_assignment.deployer_kv_admin, azurerm_private_endpoint.vault]
}

resource "azurerm_key_vault_key" "disks" {
  name         = "cmk-loki-disks"
  key_vault_id = azurerm_key_vault.obs.id
  key_type     = "RSA-HSM"
  key_size     = 3072
  key_opts     = ["wrapKey", "unwrapKey"]
  rotation_policy {
    expire_after         = "P2Y"
    notify_before_expiry = "P30D"
    automatic {
      time_before_expiry = "P60D"
    }
  }
  depends_on = [azurerm_role_assignment.deployer_kv_admin, azurerm_private_endpoint.vault]
}

# Platform secrets, read by External Secrets (charts/log-platform/templates/external-secrets.yaml).
# Per-view gateway keys are NOT here: scripts/tenant-keys.sh creates them, so
# onboarding a tenant never needs a Terraform run.
resource "random_password" "grafana_admin" {
  length  = 40
  special = false
}

resource "random_password" "grafana_db" {
  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "grafana_admin_user" {
  name         = "grafana-admin-user"
  value        = "platform-breakglass"
  key_vault_id = azurerm_key_vault.obs.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin, azurerm_private_endpoint.vault]
}

resource "azurerm_key_vault_secret" "grafana_admin_password" {
  name         = "grafana-admin-password"
  value        = random_password.grafana_admin.result
  content_type = "break-glass; rotate after every use"
  key_vault_id = azurerm_key_vault.obs.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin, azurerm_private_endpoint.vault]
}

resource "azurerm_key_vault_secret" "grafana_db_password" {
  name         = "grafana-db-password"
  value        = random_password.grafana_db.result
  content_type = "password of the `grafana` PostgreSQL role (docs/06, first install)"
  key_vault_id = azurerm_key_vault.obs.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin, azurerm_private_endpoint.vault]
}

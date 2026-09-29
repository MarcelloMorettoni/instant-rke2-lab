# Grafana's database: dashboards, orgs, users, alert rules and their state.
# Zone-redundant HA (standby in another zone, automatic failover), private
# access only, 35-day point-in-time restore, geo-redundant backups for DR.
resource "random_password" "postgres_admin" {
  length  = 40
  special = false
}

resource "azurerm_postgresql_flexible_server" "grafana" {
  name                          = "psql-grafana-${local.suffix}"
  location                      = azurerm_resource_group.obs.location
  resource_group_name           = azurerm_resource_group.obs.name
  version                       = "16"
  sku_name                      = "GP_Standard_D2ds_v5"
  storage_mb                    = 65536
  auto_grow_enabled             = true
  delegated_subnet_id           = var.postgres_subnet_id
  private_dns_zone_id           = var.private_dns_zone_ids.postgres
  public_network_access_enabled = false
  administrator_login           = "pgadmin"
  administrator_password        = random_password.postgres_admin.result
  backup_retention_days         = 35
  geo_redundant_backup_enabled  = true
  zone                          = "1"

  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = "2"
  }

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  maintenance_window {
    day_of_week  = 0
    start_hour   = 2
    start_minute = 0
  }

  tags = local.tags
  lifecycle {
    # Azure swaps these after an HA failover; don't fail back on the next apply.
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "grafana" {
  name      = "grafana"
  server_id = azurerm_postgresql_flexible_server.grafana.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_configuration" "require_tls" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.grafana.id
  value     = "on"
}

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  name         = "postgres-admin-password"
  value        = random_password.postgres_admin.result
  content_type = "PostgreSQL server admin; DBA use only"
  key_vault_id = azurerm_key_vault.obs.id
  depends_on   = [azurerm_role_assignment.deployer_kv_admin, azurerm_private_endpoint.vault]
}

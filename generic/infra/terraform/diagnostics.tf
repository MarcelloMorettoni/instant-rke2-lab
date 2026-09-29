# Who touched the log store and its keys: to the bank's Log Analytics / SIEM.
resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                       = "audit-to-law"
  target_resource_id         = "${azurerm_storage_account.loki.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
  enabled_metric {
    category = "Transaction"
  }
}

resource "azurerm_monitor_diagnostic_setting" "vault" {
  name                       = "audit-to-law"
  target_resource_id         = azurerm_key_vault.obs.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "audit-to-law"
  target_resource_id         = azurerm_postgresql_flexible_server.grafana.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "PostgreSQLLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

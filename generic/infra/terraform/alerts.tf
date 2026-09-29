# The alert rules live once, in Prometheus format, in
# alerts/loki-alerts.yaml (checked by promtool in validate.sh).
# Here they become Azure Monitor managed Prometheus rule groups.
locals {
  alert_groups = yamldecode(file("${path.module}/../../alerts/loki-alerts.yaml")).groups
  # Azure severities: 0 critical ... 4 verbose.
  severity = { critical = 0, warning = 2, info = 3 }
  # Prometheus "10m" → ISO 8601 "PT10M".
  iso = { for d in ["5m", "10m", "15m", "30m", "1h"] : d => "PT${upper(d)}" }
}

resource "azurerm_monitor_alert_prometheus_rule_group" "loki" {
  for_each            = { for g in local.alert_groups : g.name => g }
  name                = "obs-${each.key}"
  location            = azurerm_resource_group.obs.location
  resource_group_name = azurerm_resource_group.obs.name
  cluster_name        = data.azurerm_kubernetes_cluster.aks.name
  scopes              = [var.azure_monitor_workspace_id, data.azurerm_kubernetes_cluster.aks.id]
  rule_group_enabled  = true
  interval            = "PT1M"

  dynamic "rule" {
    for_each = each.value.rules
    content {
      alert       = rule.value.alert
      expression  = rule.value.expr
      for         = try(local.iso[rule.value["for"]], null)
      severity    = local.severity[rule.value.labels.severity]
      labels      = rule.value.labels
      annotations = rule.value.annotations
      enabled     = true
      action {
        action_group_id = var.action_group_id
      }
      alert_resolution {
        auto_resolved   = true
        time_to_resolve = "PT10M"
      }
    }
  }
  tags = local.tags
}

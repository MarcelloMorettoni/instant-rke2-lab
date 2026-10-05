output "storage_account_name" {
  value = azurerm_storage_account.loki.name
}

output "loki_client_id" {
  description = "loki.serviceAccount.annotations.azure.workload.identity/client-id (environment values)"
  value       = azurerm_user_assigned_identity.loki.client_id
}

output "eso_client_id" {
  description = "external-secrets.serviceAccount.annotations.azure.workload.identity/client-id (environment values)"
  value       = azurerm_user_assigned_identity.eso.client_id
}

output "key_vault_name" {
  value = azurerm_key_vault.obs.name
}

output "key_vault_uri" {
  description = "keyVault.url (environment values)"
  value       = azurerm_key_vault.obs.vault_uri
}

output "disk_encryption_set_id" {
  description = "storageClass.diskEncryptionSetID (environment values)"
  value       = azurerm_disk_encryption_set.loki.id
}

output "postgres_fqdn" {
  description = "postgres.azure.host (environment values)"
  value       = azurerm_postgresql_flexible_server.grafana.fqdn
}

# Paste-ready environment values for BOTH charts:
#   terraform -chdir=infra/terraform output -raw environment_values > environments/<env>/terraform.yaml
# and add `-f environments/<env>/terraform.yaml` after values.yaml (install.sh does if present).
output "environment_values" {
  value = yamlencode({
    storageClass = { diskEncryptionSetID = azurerm_disk_encryption_set.loki.id }
    keyVault     = { url = azurerm_key_vault.obs.vault_uri }
    loki = {
      loki           = { storage = { azure = { accountName = azurerm_storage_account.loki.name } } }
      serviceAccount = { annotations = { "azure.workload.identity/client-id" = azurerm_user_assigned_identity.loki.client_id } }
    }
    postgres = { azure = { host = azurerm_postgresql_flexible_server.grafana.fqdn } }
    "external-secrets" = {
      serviceAccount = { annotations = { "azure.workload.identity/client-id" = azurerm_user_assigned_identity.eso.client_id } }
    }
  })
}

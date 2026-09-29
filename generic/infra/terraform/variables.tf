variable "environment" {
  description = "Short environment name, used in resource names (prod, uat, ...)."
  type        = string
}

variable "location" {
  description = "Azure region of the AKS cluster, e.g. westeurope. Must have 3 availability zones."
  type        = string
}

variable "location_short" {
  description = "Short region code for names, e.g. weu."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the log platform's Azure resources (created here)."
  type        = string
}

variable "aks_name" {
  description = "Existing AKS cluster. OIDC issuer and Workload Identity must be enabled."
  type        = string
}

variable "aks_resource_group_name" {
  type = string
}

variable "node_subnet_id" {
  description = "Subnet for the Loki node pools (same VNet as the cluster)."
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Subnet for the Blob and Key Vault private endpoints."
  type        = string
}

variable "postgres_subnet_id" {
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers."
  type        = string
}

variable "private_dns_zone_ids" {
  description = "Central (hub) private DNS zones: blob, vault, postgres."
  type = object({
    blob     = string # privatelink.blob.core.windows.net
    vault    = string # privatelink.vaultcore.azure.net
    postgres = string # <name>.private.postgres.database.azure.com
  })
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving the storage account's and Key Vault's audit logs."
  type        = string
}

variable "azure_monitor_workspace_id" {
  description = "Azure Monitor workspace (managed Prometheus) that scrapes the cluster."
  type        = string
}

variable "action_group_id" {
  description = "Action group paged by the log platform's alerts."
  type        = string
}

variable "loki_vm_size" {
  description = "VM size for the Loki node pools. Needs a local temp disk for the ephemeral OS disk."
  type        = string
  default     = "Standard_D16ds_v5"
}

variable "loki_nodes_per_zone" {
  description = "Autoscaler bounds of each zonal Loki node pool."
  type = object({
    min = number
    max = number
  })
  default = { min = 2, max = 5 }
}

variable "storage_replication" {
  description = "GZRS: 3 zones here + async copy to the paired region (DR). ZRS if data must not leave the region."
  type        = string
  default     = "GZRS"
  validation {
    condition     = contains(["ZRS", "GZRS", "RAGZRS"], var.storage_replication)
    error_message = "Use a zone-redundant SKU: ZRS, GZRS or RAGZRS."
  }
}

variable "cool_after_days" {
  description = "Move chunks to the Cool tier after this many days (Cool has a 30-day minimum)."
  type        = number
  default     = 30
}

variable "cold_after_days" {
  description = "Move chunks to the Cold tier after this many days (Cold has a 90-day minimum). Never Archive: Loki can't read it."
  type        = number
  default     = 180
}

variable "max_retention_days" {
  description = "Longest retention of any tenant tier (tenants.yaml). The lifecycle rule deletes 30 days after it, as a safety net behind the compactor."
  type        = number
  default     = 396
}

variable "tags" {
  type    = map(string)
  default = {}
}

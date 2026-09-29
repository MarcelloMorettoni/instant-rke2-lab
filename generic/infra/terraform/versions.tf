terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # State holds generated secrets (DB and break-glass passwords): keep it in a
  # private, encrypted, access-controlled backend, e.g.
  # backend "azurerm" { use_azuread_auth = true ... }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
  # Shared keys are disabled on the storage account: data-plane calls use Entra ID.
  storage_use_azuread = true
}

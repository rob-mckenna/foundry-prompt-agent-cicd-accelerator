terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Configure remote state per environment with a partial backend, for example:
  #   terraform init -backend-config=environments/dev.backend.hcl
  # Never commit access keys: the backend below uses Entra ID authentication.
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }

  # Credentials come from the environment: GitHub OIDC (ARM_USE_OIDC=true) or the Azure CLI session
  # established by an Azure DevOps workload identity federation service connection.
  storage_use_azuread = true
  subscription_id     = var.subscription_id
}

provider "azapi" {
  # azapi covers Foundry project and connection resource types that azurerm does not yet model.
}
# Partial backend configuration for the DEV environment.
# Usage: terraform init -backend-config=environments/dev.backend.hcl
# Authentication uses Entra ID (use_azuread_auth = true in versions.tf). No storage key is required.

resource_group_name  = "rg-tfstate-dev"
storage_account_name = "REPLACEtfstatedev"
container_name       = "tfstate"
key                  = "foundry-agents/dev.tfstate"

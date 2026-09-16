# Partial backend configuration for the UAT environment.
# Usage: terraform init -backend-config=environments/uat.backend.hcl
# Authentication uses Entra ID (use_azuread_auth = true in versions.tf). No storage key is required.

resource_group_name  = "rg-tfstate-uat"
storage_account_name = "REPLACEtfstateuat"
container_name       = "tfstate"
key                  = "foundry-agents/uat.tfstate"

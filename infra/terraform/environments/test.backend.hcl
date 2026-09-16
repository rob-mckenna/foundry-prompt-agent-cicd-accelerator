# Partial backend configuration for the TEST environment.
# Usage: terraform init -backend-config=environments/test.backend.hcl
# Authentication uses Entra ID (use_azuread_auth = true in versions.tf). No storage key is required.

resource_group_name  = "rg-tfstate-test"
storage_account_name = "REPLACEtfstatetest"
container_name       = "tfstate"
key                  = "foundry-agents/test.tfstate"

# Partial backend configuration for the PROD environment.
# Usage: terraform init -backend-config=environments/prod.backend.hcl
# Authentication uses Entra ID (use_azuread_auth = true in versions.tf). No storage key is required.

resource_group_name  = "rg-tfstate-prod"
storage_account_name = "REPLACEtfstateprod"
container_name       = "tfstate"
key                  = "foundry-agents/prod.tfstate"

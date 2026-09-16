# Terraform variables for the UAT environment.
# Apply with:
#   terraform init -backend-config=environments/uat.backend.hcl
#   terraform apply -var-file=environments/uat.tfvars
#
# subscription_id is intentionally absent: supply it through ARM_SUBSCRIPTION_ID or
# TF_VAR_subscription_id so that no subscription identifier is committed.

workload_name       = "fndagents"
environment_name    = "uat"
location            = "eastus2"
resource_group_name = "rg-foundry-agents-uat"

tags = {
  costCenter         = "REPLACE-cost-center"
  owner              = "REPLACE-platform-team"
  dataClassification = "internal"
}

# Object ids of the CI/CD workload identity and the operator group.
# Leaving these empty skips the role assignments and the pipeline will not be able to deploy agents.
deployment_principal_id     = ""
agent_operator_principal_id = ""

deploy_ai_search              = true
ai_search_sku                 = "standard"
public_network_access_enabled = true
log_retention_days            = 90

model_deployments = [
  {
    name          = "gpt-4o-mini"
    model_name    = "gpt-4o-mini"
    model_version = "2024-07-18"
    sku_name      = "GlobalStandard"
    capacity      = 50
  },
  {
    name          = "gpt-4o"
    model_name    = "gpt-4o"
    model_version = "2024-11-20"
    sku_name      = "GlobalStandard"
    capacity      = 50
  },
]

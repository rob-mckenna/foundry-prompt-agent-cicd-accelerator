# Terraform infrastructure

Equivalent to `infra/bicep`, for teams whose platform standard is Terraform. Pick one. Running both against
the same resource group will cause the two state models to fight.

## Providers

| Provider | Version | Used for |
| --- | --- | --- |
| `hashicorp/azurerm` | `~> 4.20` | Cognitive account, model deployments, Key Vault, storage, search, monitoring, RBAC |
| `Azure/azapi` | `~> 2.2` | `allowProjectManagement` on the account and the Foundry project child resource, which azurerm does not yet model |
| `hashicorp/random` | `~> 3.6` | Reserved for future name randomisation |

`azapi` is used deliberately and narrowly. The Foundry project resource type
(`Microsoft.CognitiveServices/accounts/projects`) has no first-class azurerm resource, and using `azapi` with
a pinned API version is more honest than a local-exec shell-out.

## Authentication

No credentials are stored in this repository.

```powershell
# Interactive
az login
$env:ARM_SUBSCRIPTION_ID = '<subscription guid>'
$env:TF_VAR_subscription_id = $env:ARM_SUBSCRIPTION_ID
```

In GitHub Actions, OIDC:

```yaml
env:
  ARM_USE_OIDC: true
  ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
  ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  TF_VAR_subscription_id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

In Azure DevOps, run Terraform inside an `AzureCLI@2` task backed by a workload identity federation service
connection and set `ARM_USE_AZURECLI_AUTH=true`.

The state backend uses `use_azuread_auth = true`, so no storage account key is needed or accepted.

## Deploy

```powershell
cd infra/terraform

terraform init -backend-config=environments/dev.backend.hcl
terraform plan  -var-file=environments/dev.tfvars -out=dev.tfplan
terraform apply dev.tfplan
```

Copy the outputs into `config/environments/dev.json`:

| Output | Config field |
| --- | --- |
| `foundry_account_name` | `foundry.accountName` |
| `foundry_project_name` | `foundry.projectName` |
| `foundry_project_endpoint` | `foundry.projectEndpoint` |
| `key_vault_name` / `key_vault_uri` | `keyVault.name` / `keyVault.uri` |
| `release_store_account_name` | `releaseStore.accountName` |
| `queue_service_endpoint` | `FUNCTION_QUEUE_ENDPOINT` overlay variable |

`application_insights_connection_string` is marked `sensitive` and is not printed by `terraform output`
without `-raw`.

## Values you must supply

`environments/<env>.tfvars`:

- `resource_group_name`, `location`
- `tags.costCenter`, `tags.owner`
- `deployment_principal_id`: object id of the CI/CD service principal
- `agent_operator_principal_id`: object id of the operator group
- `model_deployments`: names, versions and capacity approved for your region

`environments/<env>.backend.hcl`:

- `resource_group_name`, `storage_account_name` of your existing Terraform state account

`subscription_id` is deliberately not in any tfvars file. Supply it through `ARM_SUBSCRIPTION_ID` or
`TF_VAR_subscription_id`.

## Security choices

- `shared_access_key_enabled = false` on storage: no connection string exists to leak.
- `local_auth_enabled = false` on the Foundry account and `local_authentication_enabled = false` on search:
  Entra ID only, so there are no API keys to rotate or accidentally commit.
- `rbac_authorization_enabled = true` and `purge_protection_enabled = true` on Key Vault.
- `version_upgrade_option = "NoAutoUpgrade"` on model deployments: a promoted package keeps behaving the same
  because the model version cannot change beneath it.

## Validation

```powershell
cd infra/terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

`terraform fmt -check -recursive` is offline and always runs in `scripts/Invoke-Validation.ps1`.
`terraform validate` needs `terraform init` to download providers, so it is opt-in locally with
`./scripts/Invoke-Validation.ps1 -IncludeTerraformValidate` and runs unconditionally in `validate.yml`, where
network access is available.

## Not created here, on purpose

The same exclusions as the Bicep template: resource group policy, search index schema and content, Foundry
project connections that carry credentials, private endpoints, and the preview `capabilityHosts` standard
agent setup.

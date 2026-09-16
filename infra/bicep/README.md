# Bicep infrastructure

Provisions one Azure AI Foundry environment per deployment. Scope is resource group, so the resource group
and its policy assignments stay under landing zone control.

## What is created

| Resource | Purpose | Notes |
| --- | --- | --- |
| `Microsoft.CognitiveServices/accounts` (kind `AIServices`) | Foundry account | `allowProjectManagement: true`, `disableLocalAuth: true`, system assigned identity |
| `.../accounts/projects` | Foundry project that hosts the agents | System assigned identity; this is the identity your knowledge sources must trust |
| `.../accounts/deployments` | Model deployments | Created one at a time; `versionUpgradeOption: NoAutoUpgrade` so a model version never changes underneath a promoted package |
| `Microsoft.KeyVault/vaults` | Agent secrets | RBAC only, purge protection on. No secret values are created here |
| `Microsoft.Storage/storageAccounts` | Release records, package copies, tool queues | `allowSharedKeyAccess: false`, versioning on |
| `Microsoft.Search/searchServices` | Knowledge for RAG agents | Optional (`deployAiSearch`), `disableLocalAuth: true` |
| Log Analytics + Application Insights | Diagnostics and agent telemetry | Diagnostic settings wired for account, vault, storage and search |
| Role assignments | Least privilege wiring | See the table below |

## Role assignments

| Principal | Role | Scope | Why |
| --- | --- | --- | --- |
| Project managed identity | Search Index Data Reader | resource group | The project reads the knowledge index |
| Project managed identity | Storage Queue Data Contributor | resource group | `azure_function` tools exchange messages over queues |
| Project managed identity | Key Vault Secrets User | resource group | Connections that resolve secrets at run time |
| CI/CD identity | Azure AI User | resource group | Create and update agents on the data plane |
| CI/CD identity | Key Vault Secrets User | resource group | Resolve `secretRefs` during deployment |
| CI/CD identity | Storage Blob Data Contributor | resource group | Write release records |
| Operator group | Azure AI User | resource group | Humans inspect and test agents in the portal |

Assignments are made at resource group scope with deterministic `guid()` names, so redeployment is idempotent.
Tighten to individual resource scopes if your standard requires it.

## Deploy

```powershell
az login
az account set --subscription '<subscription guid>'
az group create --name rg-foundry-agents-dev --location eastus2

az deployment group what-if `
  --resource-group rg-foundry-agents-dev `
  --template-file infra/bicep/main.bicep `
  --parameters infra/bicep/parameters/dev.bicepparam

az deployment group create `
  --resource-group rg-foundry-agents-dev `
  --template-file infra/bicep/main.bicep `
  --parameters infra/bicep/parameters/dev.bicepparam
```

Then copy the outputs into `config/environments/dev.json`:

| Output | Config field |
| --- | --- |
| `foundryAccountName` | `foundry.accountName` |
| `foundryProjectName` | `foundry.projectName` |
| `foundryProjectEndpoint` | `foundry.projectEndpoint` |
| `keyVaultName` / `keyVaultUri` | `keyVault.name` / `keyVault.uri` |
| `releaseStoreAccountName` | `releaseStore.accountName` |
| `queueServiceEndpoint` | `FUNCTION_QUEUE_ENDPOINT` overlay variable |

## Values you must supply

`infra/bicep/parameters/<env>.bicepparam`:

- `tags.costCenter`, `tags.owner`
- `deploymentPrincipalId`: object id of the service principal behind your federated credential. Empty skips
  the CI/CD role assignments, which will make deployments fail with 403 later.
- `agentOperatorPrincipalId`: object id of the operator Entra ID group.
- `modelDeployments`: names, versions and capacity that exist and are approved in your region.

## Not created here, on purpose

- **Resource group and policy**: owned by the landing zone.
- **Search indexes and their content**: owned by the knowledge pipeline. Agents bind to an index by name.
- **Foundry project connections** (to search, APIs, Bing): these carry credentials and target URLs that differ
  per environment. Create them once per environment with `az cognitiveservices` or the portal, then reference
  the connection id from the agent overlay. Creating them in IaC would place a credential in template
  parameters.
- **Private endpoints and DNS**: set `publicNetworkAccess` to `Disabled` and add your standard private
  endpoint module when your landing zone requires network isolation.
- **Standard agent setup with bring-your-own storage, search and Cosmos DB** (`capabilityHosts`): this is a
  preview surface whose resource shape has changed between API versions. Add it deliberately once you have
  confirmed the shape for your tenant rather than inheriting it from a template.

## Validation

```powershell
az bicep build --file infra/bicep/main.bicep --stdout
az bicep build-params --file infra/bicep/parameters/prod.bicepparam --stdout
```

Both run offline and are executed by `scripts/Invoke-Validation.ps1` and by `validate.yml`.
`bicepconfig.json` turns `no-unused-params`, `secure-parameter-default` and
`outputs-should-not-contain-secrets` into errors.

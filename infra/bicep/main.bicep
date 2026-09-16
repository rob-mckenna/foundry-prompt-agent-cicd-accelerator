metadata description = '''
Provisions one Azure AI Foundry environment for prompt agent CI/CD: a Foundry (AIServices) account with
project management enabled, a Foundry project, a model deployment, Key Vault, a storage account used for
release records and agent artifacts, optional Azure AI Search, Log Analytics and Application Insights, plus
the role assignments the deployment identity and the project managed identity need.

Scope: resource group. Deploy with:

  az deployment group create \
    --resource-group rg-foundry-agents-dev \
    --template-file infra/bicep/main.bicep \
    --parameters infra/bicep/parameters/dev.bicepparam

All names are derived from workloadName + environmentName + a uniqueString suffix unless overridden.
'''

targetScope = 'resourceGroup'

import { modelDeploymentType } from 'types.bicep'

@description('Short workload name used to build resource names. Lowercase letters and digits only.')
@minLength(3)
@maxLength(12)
param workloadName string

@description('Environment short name.')
@allowed([ 'dev', 'test', 'uat', 'prod' ])
param environmentName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Tags applied to every resource. costCenter and owner are expected by the tagging policy.')
param tags object = {}

@description('Object id of the principal (group preferred) that operates agents in this environment. Receives the Azure AI User role on the project.')
param agentOperatorPrincipalId string = ''

@description('Principal type of agentOperatorPrincipalId.')
@allowed([ 'Group', 'ServicePrincipal', 'User' ])
param agentOperatorPrincipalType string = 'Group'

@description('Object id of the CI/CD deployment identity (the federated credential service principal). Receives data plane and release store permissions.')
param deploymentPrincipalId string = ''

@description('Deploy an Azure AI Search service for retrieval augmented agents.')
param deployAiSearch bool = false

@description('Azure AI Search SKU. basic is the minimum that supports semantic ranking in most regions.')
@allowed([ 'basic', 'standard', 'standard2', 'standard3' ])
param aiSearchSku string = 'basic'

@description('Model deployments to create on the Foundry account.')
param modelDeployments modelDeploymentType[] = [
  {
    name: 'gpt-4o-mini'
    modelName: 'gpt-4o-mini'
    modelVersion: '2024-07-18'
    skuName: 'GlobalStandard'
    capacity: 30
  }
]

@description('Restrict data plane access to the Foundry account to selected networks. Set to Disabled only for isolated environments with private endpoints already in place.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

var suffix = uniqueString(resourceGroup().id, workloadName, environmentName)
var baseName = toLower('${workloadName}${environmentName}')
var commonTags = union(
  {
    workload: workloadName
    environment: environmentName
    managedBy: 'foundry-prompt-agent-cicd-accelerator'
  },
  tags
)

// Well-known role definition ids.
var roles = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  cognitiveServicesUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  azureAiUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  azureAiProjectManager: 'eadc314b-1a2d-4efa-be10-5d325db5065e'
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: 'log-${baseName}-${suffix}'
    appInsightsName: 'appi-${baseName}-${suffix}'
    location: location
    tags: commonTags
    retentionInDays: logRetentionDays
  }
}

module keyVault 'modules/key-vault.bicep' = {
  name: 'keyVault'
  params: {
    name: take('kv-${baseName}-${suffix}', 24)
    location: location
    tags: commonTags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    name: take('st${baseName}${suffix}', 24)
    location: location
    tags: commonTags
    containerNames: [ 'agent-releases', 'agent-packages' ]
    queueNames: [ 'entitlement-input', 'entitlement-output' ]
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module aiSearch 'modules/ai-search.bicep' = if (deployAiSearch) {
  name: 'aiSearch'
  params: {
    name: take('srch-${baseName}-${suffix}', 60)
    location: location
    tags: commonTags
    sku: aiSearchSku
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module foundry 'modules/foundry-account.bicep' = {
  name: 'foundryAccount'
  params: {
    accountName: take('aif${baseName}${suffix}', 24)
    projectName: 'proj-${workloadName}-${environmentName}'
    projectDisplayName: '${workloadName} agents (${environmentName})'
    location: location
    tags: commonTags
    publicNetworkAccess: publicNetworkAccess
    modelDeployments: modelDeployments
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

// The project managed identity reads knowledge and writes to the function queues.
module projectSearchRole 'modules/role-assignment.bicep' = if (deployAiSearch) {
  name: 'roleProjectSearchReader'
  params: {
    principalId: foundry.outputs.projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roles.searchIndexDataReader
    resourceIdForName: '${foundry.outputs.projectId}/search-reader'
  }
}

module projectQueueRole 'modules/role-assignment.bicep' = {
  name: 'roleProjectQueueContributor'
  params: {
    principalId: foundry.outputs.projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roles.storageQueueDataContributor
    resourceIdForName: '${foundry.outputs.projectId}/queue-contributor'
  }
}

module projectKeyVaultRole 'modules/role-assignment.bicep' = {
  name: 'roleProjectKeyVaultSecretsUser'
  params: {
    principalId: foundry.outputs.projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roles.keyVaultSecretsUser
    resourceIdForName: '${foundry.outputs.projectId}/kv-secrets-user'
  }
}

// The CI/CD deployment identity creates agents, reads secrets and writes release records.
module deploymentAiRole 'modules/role-assignment.bicep' = if (!empty(deploymentPrincipalId)) {
  name: 'roleDeploymentAzureAiUser'
  params: {
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roles.azureAiUser
    resourceIdForName: '${resourceGroup().id}/deployment-ai-user'
  }
}

module deploymentKeyVaultRole 'modules/role-assignment.bicep' = if (!empty(deploymentPrincipalId)) {
  name: 'roleDeploymentKeyVaultSecretsUser'
  params: {
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roles.keyVaultSecretsUser
    resourceIdForName: '${resourceGroup().id}/deployment-kv-secrets-user'
  }
}

module deploymentStorageRole 'modules/role-assignment.bicep' = if (!empty(deploymentPrincipalId)) {
  name: 'roleDeploymentStorageBlobContributor'
  params: {
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roles.storageBlobDataContributor
    resourceIdForName: '${resourceGroup().id}/deployment-blob-contributor'
  }
}

// Human operators.
module operatorAiRole 'modules/role-assignment.bicep' = if (!empty(agentOperatorPrincipalId)) {
  name: 'roleOperatorAzureAiUser'
  params: {
    principalId: agentOperatorPrincipalId
    principalType: agentOperatorPrincipalType
    roleDefinitionId: roles.azureAiUser
    resourceIdForName: '${resourceGroup().id}/operator-ai-user'
  }
}

@description('Foundry account name. Use for config/environments/<env>.json foundry.accountName.')
output foundryAccountName string = foundry.outputs.accountName

@description('Foundry project name. Use for foundry.projectName.')
output foundryProjectName string = foundry.outputs.projectName

@description('Agent Service data plane endpoint. Use verbatim for foundry.projectEndpoint.')
output foundryProjectEndpoint string = foundry.outputs.projectEndpoint

@description('Managed identity principal id of the project. Grant it access to any data source the agents read.')
output foundryProjectPrincipalId string = foundry.outputs.projectPrincipalId

@description('Key Vault name. Use for keyVault.name.')
output keyVaultName string = keyVault.outputs.name

@description('Key Vault URI. Use for keyVault.uri.')
output keyVaultUri string = keyVault.outputs.uri

@description('Storage account name holding release records. Use for releaseStore.accountName.')
output releaseStoreAccountName string = storage.outputs.name

@description('Queue service endpoint. Use for the FUNCTION_QUEUE_ENDPOINT overlay variable.')
output queueServiceEndpoint string = storage.outputs.queueEndpoint

@description('Azure AI Search endpoint, empty when deployAiSearch is false.')
output aiSearchEndpoint string = deployAiSearch ? aiSearch!.outputs.endpoint : ''

@description('Application Insights connection string for agent telemetry dashboards.')
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString

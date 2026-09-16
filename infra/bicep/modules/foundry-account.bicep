metadata description = 'Azure AI Foundry account (Microsoft.CognitiveServices/accounts, kind AIServices) with project management enabled, one Foundry project, and pinned model deployments.'

@description('Foundry account name. Must be globally unique and 2-64 characters.')
@minLength(2)
@maxLength(64)
param accountName string

@description('Foundry project name.')
@minLength(2)
@maxLength(64)
param projectName string

@description('Friendly project name shown in the Azure AI Foundry portal.')
param projectDisplayName string

param location string
param tags object

@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string

import { modelDeploymentType } from '../types.bicep'

@description('Model deployments created on the account and referenced by agent overlays.')
param modelDeployments modelDeploymentType[]

@description('Log Analytics workspace resource id for diagnostic settings.')
param logAnalyticsWorkspaceId string

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // allowProjectManagement enables the Foundry project resource type on this account.
    allowProjectManagement: true
    customSubDomainName: accountName
    publicNetworkAccess: publicNetworkAccess
    disableLocalAuth: true
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Enabled' ? 'Allow' : 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectDisplayName
    description: 'Prompt agents deployed by the CI/CD accelerator.'
  }
}

// Model deployments are created sequentially: the service rejects parallel writes to the same account.
@batchSize(1)
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [
  for modelDeployment in modelDeployments: {
    parent: account
    name: modelDeployment.name
    sku: {
      name: modelDeployment.skuName
      capacity: modelDeployment.capacity
    }
    properties: {
      model: {
        format: 'OpenAI'
        name: modelDeployment.modelName
        version: modelDeployment.modelVersion
      }
      versionUpgradeOption: 'NoAutoUpgrade'
      raiPolicyName: 'Microsoft.DefaultV2'
    }
  }
]

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: account
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output accountName string = account.name
output accountId string = account.id
output projectName string = project.name
output projectId string = project.id

@description('System assigned managed identity of the project. Grant it data access on knowledge sources.')
output projectPrincipalId string = project.identity.principalId

@description('Agent Service data plane endpoint for this project.')
output projectEndpoint string = '${account.properties.endpoints['AI Foundry API']}api/projects/${project.name}'

@description('Names of the model deployments created, for use in environment overlays.')
output modelDeploymentNames array = [for modelDeployment in modelDeployments: modelDeployment.name]

metadata description = 'Azure AI Search service for retrieval augmented agents. Indexes and their content are owned by the knowledge pipeline, not by this template.'

param name string
param location string
param tags object
param logAnalyticsWorkspaceId string

@allowed([ 'basic', 'standard', 'standard2', 'standard3' ])
param sku string

@minValue(1)
@maxValue(12)
param replicaCount int = 1

@minValue(1)
@maxValue(12)
param partitionCount int = 1

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: replicaCount
    partitionCount: partitionCount
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    // Entra ID only: no admin or query keys are issued or stored.
    disableLocalAuth: true
    authOptions: null
    semanticSearch: sku == 'basic' ? 'free' : 'standard'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: search
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'OperationLogs'
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

output name string = search.name
output id string = search.id
output endpoint string = 'https://${search.name}.search.windows.net'
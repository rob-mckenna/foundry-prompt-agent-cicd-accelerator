metadata description = 'Key Vault for agent secrets. RBAC authorization only, soft delete and purge protection enabled. No secret values are created by this template.'

@minLength(3)
@maxLength(24)
param name string
param location string
param tags object
param logAnalyticsWorkspaceId string

@description('Enable purge protection. Required for production; irreversible once enabled.')
param enablePurgeProtection bool = true

@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    // RBAC only: access policies are not used, so no policy drift between environments.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'audit'
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

output name string = vault.name
output id string = vault.id
output uri string = vault.properties.vaultUri
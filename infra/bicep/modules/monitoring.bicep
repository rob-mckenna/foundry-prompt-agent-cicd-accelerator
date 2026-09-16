metadata description = 'Log Analytics workspace and Application Insights used for agent telemetry and pipeline diagnostics.'

param logAnalyticsName string
param appInsightsName string
param location string
param tags object

@minValue(30)
@maxValue(730)
param retentionInDays int

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    DisableLocalAuth: true
  }
}

output logAnalyticsWorkspaceId string = workspace.id
output appInsightsId string = appInsights.id

@description('Connection string only. Instrumentation keys are not emitted.')
output appInsightsConnectionString string = appInsights.properties.ConnectionString
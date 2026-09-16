using '../main.bicep'

// Parameters for the TEST environment.
// Replace the placeholder object ids before the first deployment. Leaving them empty skips the
// corresponding role assignment, which means the pipeline will not be able to deploy agents.

param workloadName = 'fndagents'
param environmentName = 'test'
param location = 'eastus2'

param tags = {
  costCenter: 'REPLACE-cost-center'
  owner: 'REPLACE-platform-team'
  dataClassification: 'internal'
}

// Entra ID group of humans who operate agents in this environment.
param agentOperatorPrincipalId = ''
param agentOperatorPrincipalType = 'Group'

// Service principal behind the GitHub OIDC or Azure DevOps workload identity federation credential.
param deploymentPrincipalId = ''

param deployAiSearch = true
param aiSearchSku = 'basic'
param publicNetworkAccess = 'Enabled'
param logRetentionDays = 60

param modelDeployments = [
  {
    name: 'gpt-4o-mini'
    modelName: 'gpt-4o-mini'
    modelVersion: '2024-07-18'
    skuName: 'GlobalStandard'
    capacity: 50
  }
]

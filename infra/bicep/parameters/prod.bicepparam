using '../main.bicep'

// Parameters for the PROD environment.
// Replace the placeholder object ids before the first deployment. Leaving them empty skips the
// corresponding role assignment, which means the pipeline will not be able to deploy agents.

param workloadName = 'fndagents'
param environmentName = 'prod'
param location = 'eastus2'

param tags = {
  costCenter: 'REPLACE-cost-center'
  owner: 'REPLACE-platform-team'
  dataClassification: 'confidential'
}

// Entra ID group of humans who operate agents in this environment.
param agentOperatorPrincipalId = ''
param agentOperatorPrincipalType = 'Group'

// Service principal behind the GitHub OIDC or Azure DevOps workload identity federation credential.
param deploymentPrincipalId = ''

param deployAiSearch = true
param aiSearchSku = 'standard'
param publicNetworkAccess = 'Enabled'
param logRetentionDays = 365

param modelDeployments = [
  {
    name: 'gpt-4o'
    modelName: 'gpt-4o'
    modelVersion: '2024-11-20'
    skuName: 'GlobalStandard'
    capacity: 150
  }
]

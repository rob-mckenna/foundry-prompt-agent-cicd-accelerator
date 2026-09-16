metadata description = 'Resource group scoped role assignment with a deterministic name so that redeployment is idempotent.'

@description('Object id of the principal receiving the role.')
param principalId string

@allowed([ 'Group', 'ServicePrincipal', 'User' ])
param principalType string

@description('Role definition GUID, without the /providers prefix.')
param roleDefinitionId string

@description('Stable string used to derive the assignment name. Include the target and the role purpose.')
param resourceIdForName string

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId, resourceIdForName)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}

output assignmentId string = assignment.id
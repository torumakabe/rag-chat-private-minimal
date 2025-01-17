param principalId string

@allowed([
  'Device'
  'ForeignGroup'
  'Group'
  'ServicePrincipal'
  'User'
])
param principalType string = 'ServicePrincipal'
param roleDefinitionId string
param cogServiceAccountName string

resource cognitiveService 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: cogServiceAccountName
}

resource role 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cognitiveService
  name: guid(subscription().id, resourceGroup().id, cognitiveService.name, roleDefinitionId, principalId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}

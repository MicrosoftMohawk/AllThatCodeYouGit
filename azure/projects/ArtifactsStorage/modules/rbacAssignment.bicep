// ============================================================================
// Module: RBAC Assignment — Storage File Data SMB Share Contributor
// Grants a user or group the ability to read/write files on the share via
// Entra ID authentication (SMB or REST).
// Role ID: 0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb
// ============================================================================

@description('Name of the storage account to scope the role to')
param storageAccountName string

@description('Azure AD object ID of the user or group')
param principalId string

@description('Principal type: User or Group')
@allowed(['User', 'Group'])
param principalType string = 'User'

var roleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
)

resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, principalId, '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
  scope: stg
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: principalType
  }
}

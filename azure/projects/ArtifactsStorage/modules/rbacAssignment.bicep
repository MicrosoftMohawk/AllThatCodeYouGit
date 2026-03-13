// ============================================================================
// Module: RBAC Assignment — Storage File Data Privileged Contributor
// Grants a user or group full read/write/delete access to file shares via
// Entra ID authentication (SMB and REST).  The "Privileged" role is required
// for REST/OAuth clients like Azure Storage Explorer that send the
// x-ms-file-request-intent: backup header.
// Role ID: 69566ab7-960f-475b-8e7c-b3118f30c6bd
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
  '69566ab7-960f-475b-8e7c-b3118f30c6bd'
)

resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, principalId, '69566ab7-960f-475b-8e7c-b3118f30c6bd')
  scope: stg
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: principalType
  }
}

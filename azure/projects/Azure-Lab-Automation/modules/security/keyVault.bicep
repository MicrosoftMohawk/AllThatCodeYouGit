// ============================================================================
// Module: Key Vault with Admin Password Secret
// Deploys an Azure Key Vault and stores the VM admin password as a secret.
// Enables template deployment so Bicep/ARM can reference secrets.
// ============================================================================

@description('Name of the Key Vault')
param keyVaultName string

@description('Azure region for deployment')
param location string

@description('The admin password to store as a secret')
@secure()
param adminPassword string

@description('Name of the secret for the admin password')
param secretName string = 'vm-admin-password'

@description('Azure AD tenant ID (for access policies)')
param tenantId string = subscription().tenantId

@description('Tags to apply to all resources')
param tags object = {}

@description('Azure AD object ID of the user or group for Key Vault Administrator role')
param deployerObjectId string = ''

@description('Principal type: User or Group')
@allowed(['User', 'Group'])
param kvPrincipalType string = 'User'

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: false
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// ---------------------------------------------------------------------------
// Secret: VM Admin Password
// ---------------------------------------------------------------------------
resource adminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: secretName
  tags: tags
  properties: {
    value: adminPassword
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: Key Vault Administrator for the deploying user
// Role ID: 00482a5a-887f-4fb3-b363-3b7fe8e74483 (Key Vault Administrator)
// ---------------------------------------------------------------------------
resource kvAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerObjectId)) {
  name: guid(kv.id, deployerObjectId, '00482a5a-887f-4fb3-b363-3b7fe8e74483')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
    principalId: deployerObjectId
    principalType: kvPrincipalType
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output keyVaultId string = kv.id
output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
output secretName string = adminPasswordSecret.name

// ============================================================================
// Module: Storage Account with Azure Files Share
// Deploys a locked-down storage account (Entra ID only, no public access)
// with a single Azure Files share for artifact storage.
// ============================================================================

@description('Globally unique storage account name')
param storageAccountName string

@description('Azure region')
param location string

@description('Name of the Azure Files share')
param shareName string = 'artifacts'

@description('Share quota in GiB')
param shareQuotaGiB int = 100

@description('Tags')
param tags object = {}

// ---------------------------------------------------------------------------
// Storage Account — fully locked down
// ---------------------------------------------------------------------------
resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// ---------------------------------------------------------------------------
// File Service + Share
// ---------------------------------------------------------------------------
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: stg
  name: 'default'
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    shareQuota: shareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output storageAccountId string = stg.id
output storageAccountName string = stg.name
output fileShareName string = share.name

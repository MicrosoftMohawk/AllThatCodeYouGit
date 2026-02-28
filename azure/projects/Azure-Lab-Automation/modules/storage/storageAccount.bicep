// ============================================================================
// Module: Storage Account (Cloud Witness)
// Deploys a StorageV2 account for WSFC Cloud Witness quorum
// ============================================================================

@description('Prefix for the storage account name (will be combined with uniqueString)')
param namePrefix string

@description('Azure region for deployment')
param location string

@description('Storage account SKU')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_ZRS'
])
param skuName string = 'Standard_LRS'

@description('Tags to apply')
param tags object = {}

// ---------------------------------------------------------------------------
// Generate a globally unique, deterministic name (max 24 chars)
// ---------------------------------------------------------------------------
var uniqueSuffix = uniqueString(resourceGroup().id, namePrefix)
var rawName = toLower('${namePrefix}${uniqueSuffix}')
var storageAccountName = length(rawName) > 24 ? substring(rawName, 0, 24) : rawName

// ---------------------------------------------------------------------------
// Storage Account
// ---------------------------------------------------------------------------
resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: skuName
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output storageAccountName string = stg.name
output storageAccountId string = stg.id

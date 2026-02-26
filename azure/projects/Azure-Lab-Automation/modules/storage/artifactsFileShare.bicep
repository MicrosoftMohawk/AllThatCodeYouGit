// ============================================================================
// Module: Artifacts Storage Account with Azure File Share
// Deploys a StorageV2 account with a 100 GB Azure Files share for hosting
// application ISOs, installers, scripts, and other deployment artefacts.
//
// Authentication:
//   - Shared key / SAS access is DISABLED (allowSharedKeyAccess = false).
//   - Azure portal / Storage Explorer: deployer gets RBAC (SMB Share Elevated
//     Contributor) so Entra ID token-based access works.
//   - Domain-joined VMs: on-prem AD DS Kerberos auth is configured
//     post-deployment by deploy.ps1 (creates a computer account in AD and
//     syncs the Kerberos key). VMs mount with:
//       net use Z: \\<stg>.file.core.windows.net\artifacts
// ============================================================================

@description('Prefix for the storage account name (combined with uniqueString, max 24 chars)')
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

@description('Name of the file share')
param fileShareName string = 'artifacts'

@description('File share quota in GiB')
param fileShareQuotaGiB int = 100

@description('Entra ID object ID to grant Storage File Data SMB Share Elevated Contributor')
param deployerObjectId string = ''

@description('Principal type for RBAC assignment: User or Group')
@allowed(['User', 'Group'])
param principalType string = 'User'

@description('Tags to apply')
param tags object = {}

// ---------------------------------------------------------------------------
// Generate a globally unique, deterministic name (max 24 chars)
// ---------------------------------------------------------------------------
var uniqueSuffix = uniqueString(resourceGroup().id, namePrefix)
var rawName = toLower('${namePrefix}${uniqueSuffix}')
var storageAccountName = length(rawName) > 24 ? substring(rawName, 0, 24) : rawName

// ---------------------------------------------------------------------------
// Built-in Role: Storage File Data SMB Share Elevated Contributor
// Allows read/write/delete/modify ACLs on Azure file shares over SMB.
// ---------------------------------------------------------------------------
var smbShareElevatedContributorRoleId = 'a7264617-510b-434b-a828-9731dc254ea7'

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
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
  }
}

// ---------------------------------------------------------------------------
// RBAC — Deployer gets SMB Share Elevated Contributor
// ---------------------------------------------------------------------------
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerObjectId)) {
  scope: stg
  name: guid(stg.id, deployerObjectId, smbShareElevatedContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', smbShareElevatedContributorRoleId)
    principalId: deployerObjectId
    principalType: principalType
  }
}

// ---------------------------------------------------------------------------
// File Service
// ---------------------------------------------------------------------------
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: stg
  name: 'default'
}

// ---------------------------------------------------------------------------
// File Share (100 GiB default)
// ---------------------------------------------------------------------------
resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: fileShareName
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output storageAccountName string = stg.name
output storageAccountId string = stg.id
output fileShareName string = share.name
output primaryFileEndpoint string = stg.properties.primaryEndpoints.file

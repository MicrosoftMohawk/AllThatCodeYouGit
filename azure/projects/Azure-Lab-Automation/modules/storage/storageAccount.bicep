// ============================================================================
// Module: Storage Account with Azure Files Share (File Share Witness)
// Deploys a locked-down StorageV2 account with an Azure Files share for
// WSFC File Share Witness quorum.  Supports optional on-premises AD DS
// authentication for Kerberos-based SMB access from domain-joined VMs.
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

@description('Name of the Azure Files share')
param shareName string = 'witness'

@description('Share quota in GiB')
param shareQuotaGiB int = 5

@description('Tags to apply')
param tags object = {}

// ---------------------------------------------------------------------------
// AD DS Identity-Based Authentication (optional)
// When enabled, domain-joined VMs can mount the share via Kerberos.
// These properties are populated post-deployment by running
// Register-StorageInAD.ps1 on the DC and then updating the storage
// account via 'az storage account update --enable-files-adds true'.
// ---------------------------------------------------------------------------

@description('Enable on-premises AD DS authentication for SMB file shares')
param enableADDS bool = false

@description('AD domain FQDN (e.g., azlab.local)')
param adDomainName string = ''

@description('AD NetBIOS domain name (e.g., AZLAB)')
param adNetBiosDomainName string = ''

@description('AD forest name (e.g., azlab.local)')
param adForestName string = ''

@description('AD domain GUID')
param adDomainGuid string = ''

@description('AD domain SID (e.g., S-1-5-21-...)')
param adDomainSid string = ''

@description('SID of the computer account created in AD for this storage account')
param adAzureStorageSid string = ''

// ---------------------------------------------------------------------------
// Generate a globally unique, deterministic name (max 24 chars)
// ---------------------------------------------------------------------------
var uniqueSuffix = uniqueString(resourceGroup().id, namePrefix)
var rawName = toLower('${namePrefix}${uniqueSuffix}')
var storageAccountName = length(rawName) > 24 ? substring(rawName, 0, 24) : rawName

// ---------------------------------------------------------------------------
// Storage Account — fully locked down
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
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    azureFilesIdentityBasedAuthentication: enableADDS ? {
      directoryServiceOptions: 'AD'
      activeDirectoryProperties: {
        domainName: adDomainName
        netBiosDomainName: adNetBiosDomainName
        forestName: adForestName
        domainGuid: adDomainGuid
        domainSid: adDomainSid
        azureStorageSid: adAzureStorageSid
      }
      defaultSharePermission: 'StorageFileDataSmbShareContributor'
    } : null
  }
}

// ---------------------------------------------------------------------------
// File Service + Share
// ---------------------------------------------------------------------------
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: stg
  name: 'default'
  properties: {
    protocolSettings: {
      smb: {
        kerberosTicketEncryption: 'AES-256'
      }
    }
  }
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
output storageAccountName string = stg.name
output storageAccountId string = stg.id
output fileShareName string = share.name

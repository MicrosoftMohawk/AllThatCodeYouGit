// ============================================================================
// Module: Storage Account with Azure Files Share
// Deploys a locked-down storage account with a single Azure Files share for
// artifact storage.  Supports optional on-premises AD DS authentication for
// Kerberos-based SMB access from domain-joined VMs.
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
// AD DS Identity-Based Authentication (optional)
// When enabled, domain-joined VMs can mount the share via Kerberos.
// The storage account is registered as a computer account in AD and the
// properties below are populated by deploy.ps1 after running the AD
// registration script on the domain controller.
// ---------------------------------------------------------------------------

@description('Enable on-premises AD DS authentication for SMB file shares')
param enableADDS bool = false

@description('Enable Entra ID Kerberos authentication for SMB file shares (alternative to AD DS)')
param enableEntraKerberos bool = false

@description('AD domain FQDN (e.g., azlab.local) — used for both AD DS and Entra Kerberos modes')
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

@description('Entra ID tenant GUID (used as domain GUID for Entra Kerberos)')
param entraIdTenantId string = ''

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
    azureFilesIdentityBasedAuthentication: enableEntraKerberos ? {
      directoryServiceOptions: 'AADKERB'
      activeDirectoryProperties: {
        domainName: adDomainName
        domainGuid: entraIdTenantId
      }
      defaultSharePermission: 'StorageFileDataSmbShareContributor'
    } : enableADDS ? {
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

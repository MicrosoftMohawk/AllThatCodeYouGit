// ============================================================================
// Artifacts Storage — Standalone File Share for Lab Assets
//
// Deploys a locked-down Azure Storage Account with an Azure Files share for
// storing lab artifacts (ISOs, installers, config files).  Access is Entra ID
// RBAC only — no shared keys, no SAS tokens, no AD DS integration.
//
// The storage account is fully private (no public network access).  A Private
// Endpoint and Private DNS Zone are deployed so the share is reachable from
// any VNet-connected client (including P2S VPN).
//
// Usage:
//   az deployment sub create \
//     --location eastus \
//     --template-file main.bicep \
//     --parameters namePrefix=artifacts location=eastus labVnetId=<vnet-resource-id>
// ============================================================================

targetScope = 'subscription'

// =============================================================================
// Parameters
// =============================================================================

@description('Name prefix for all resources (e.g., "artifacts"). Max 10 characters.')
@maxLength(10)
param namePrefix string

@description('Azure region for all resources')
param location string

@description('Resource ID of the lab VNet to link the Private DNS Zone to. This enables VPN-connected workstations to resolve the storage private endpoint. Example: /subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/...')
param labVnetId string

@description('Subnet resource ID within the lab VNet for the Private Endpoint. Example: /subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/.../subnets/snet-pe')
param peSubnetId string

@description('Azure AD object ID of the user or group to grant Storage File Data SMB Share Contributor')
param deployerObjectId string = ''

@description('Principal type for RBAC assignment')
@allowed(['User', 'Group'])
param principalType string = 'User'

@description('Azure Files share quota in GiB')
@minValue(1)
@maxValue(5120)
param shareQuotaGiB int = 100

@description('Tags applied to all resources')
param tags object = {}

// =============================================================================
// Variables
// =============================================================================

var rgName = '${namePrefix}-rg-artifacts'
var uniqueSuffix = uniqueString(subscription().id, namePrefix, 'artifacts')
var rawName = toLower('${namePrefix}stg${uniqueSuffix}')
var storageAccountName = length(rawName) > 24 ? substring(rawName, 0, 24) : rawName
var shareName = 'artifacts'
var commonTags = union(tags, {
  project: 'artifacts-storage'
  managedBy: 'bicep'
})

// Extract VNet name from resource ID for the DNS zone link name
var vnetNameSegments = split(labVnetId, '/')
var labVnetName = vnetNameSegments[length(vnetNameSegments) - 1]

// =============================================================================
// Resource Group
// =============================================================================

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: commonTags
}

// =============================================================================
// Storage Account — Private, Entra ID RBAC Only
// =============================================================================

module storage 'modules/storageAccount.bicep' = {
  name: 'deploy-storage'
  scope: rg
  params: {
    storageAccountName: storageAccountName
    location: location
    shareName: shareName
    shareQuotaGiB: shareQuotaGiB
    tags: commonTags
  }
}

// =============================================================================
// Private Endpoint + Private DNS Zone for Azure Files
// =============================================================================

module privateEndpoint 'modules/privateEndpoint.bicep' = {
  name: 'deploy-pe-files'
  scope: rg
  params: {
    storageAccountId: storage.outputs.storageAccountId
    storageAccountName: storage.outputs.storageAccountName
    subnetId: peSubnetId
    vnetId: labVnetId
    vnetLinkName: 'link-${labVnetName}'
    location: location
    tags: commonTags
  }
}

// =============================================================================
// RBAC: Storage File Data SMB Share Contributor for deployer
// Role ID: 0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb
// =============================================================================

module rbac 'modules/rbacAssignment.bicep' = if (!empty(deployerObjectId)) {
  name: 'deploy-rbac'
  scope: rg
  params: {
    storageAccountName: storage.outputs.storageAccountName
    principalId: deployerObjectId
    principalType: principalType
  }
}

// =============================================================================
// Outputs
// =============================================================================

output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.storageAccountName
output fileShareName string = shareName
output privateEndpointIp string = privateEndpoint.outputs.privateEndpointIp

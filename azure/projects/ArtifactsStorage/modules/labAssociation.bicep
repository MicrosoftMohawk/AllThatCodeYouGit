// ============================================================================
// Module: Lab Association — Re-attach existing artifacts deployment to a new lab
//
// Adds (additive only — never deletes) the resources needed to make an existing
// artifacts storage account reachable from a newly re-deployed lab whose
// BaseName may differ from the original.
//
// Creates:
//   * Optionally, a new VNet link on the artifacts private DNS zone
//     (privatelink.file.<storage-suffix>) pointing at the new lab VNet.
//     Skipped when the new lab VNet is already linked to its own zone for
//     the same namespace (Azure forbids overlapping links).
//   * A new Private Endpoint into the new lab's PE subnet, plus a DNS zone
//     group attaching it to either the artifacts zone (default) or to a
//     caller-supplied zone (e.g. the lab's own privatelink.file zone).
//
// Role assignments (Storage File Data Privileged Contributor on the storage
// account; Reader on the resource group) are handled by the wrapper script
// using `az role assignment create`, which is idempotent and tolerates
// pre-existing assignments created out-of-band.
//
// Existing PE / DNS link / AD-DS computer-object from the prior lab are left
// in place.  Re-running this module is idempotent (deterministic names).
// ============================================================================

targetScope = 'resourceGroup'

// =============================================================================
// Parameters
// =============================================================================

@description('Name of the existing artifacts storage account (e.g., artifactsstgujl67iqq77x6)')
param storageAccountName string

@description('Base name of the newly deployed lab (used to suffix the new PE name and DNS VNet link)')
param newLabBaseName string

@description('Resource ID of the newly deployed lab VNet to link the private DNS zone to')
param newLabVnetId string

@description('Subnet resource ID inside the new lab VNet to host the new Private Endpoint (typically the snet-pe subnet)')
param newPeSubnetId string

@description('Azure region for the Private Endpoint (DNS resources are global)')
param location string

@description('When true, create a new VNet link on the artifacts private DNS zone for the new lab VNet. Set false when the new lab VNet is already linked to its own privatelink.file.<suffix> zone (Azure rejects overlapping namespace links).')
param createDnsLink bool = true

@description('Optional: resource ID of an existing privatelink.file.<suffix> zone to register the new PE in (typically the new lab\'s own file zone). When empty, the artifacts RG\'s zone is used.')
param targetDnsZoneId string = ''

@description('Tags applied to new resources')
param tags object = {}

// =============================================================================
// Variables
// =============================================================================

// Extract the new lab VNet name from its resource ID for the DNS link name.
var vnetIdSegments = split(newLabVnetId, '/')
var newLabVnetName = vnetIdSegments[length(vnetIdSegments) - 1]

// Deterministic, lab-suffixed names so re-runs are idempotent and don't
// collide with the original artifacts deployment's resources.
var newPeName       = '${storageAccountName}-pe-file-${newLabBaseName}'
var newPlscName     = '${storageAccountName}-plsc-file-${newLabBaseName}'
var newDnsLinkName  = 'link-${newLabVnetName}'

// Private DNS zone for Azure Files in the current cloud (e.g. privatelink.file.core.windows.net).
var privateDnsZoneName = 'privatelink.file.${environment().suffixes.storage}'

// Effective zone to register the new PE's A record in: caller-provided zone
// when present, otherwise the artifacts RG's own zone.
var effectiveDnsZoneId = empty(targetDnsZoneId) ? dnsZone.id : targetDnsZoneId

// =============================================================================
// Existing resources (must already be present in the artifacts RG)
// =============================================================================

resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
}

// =============================================================================
// 1. Link the artifacts DNS zone to the new lab VNet (when allowed)
// Skipped if the new lab VNet is already linked to another zone with the
// same name (Azure rejects overlapping-namespace links).
// =============================================================================

resource newDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (createDnsLink) {
  parent: dnsZone
  name: newDnsLinkName
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: newLabVnetId
    }
    registrationEnabled: false
  }
}

// =============================================================================
// 2. New Private Endpoint into the new lab's PE subnet
// =============================================================================

resource newPe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: newPeName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: newPeSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: newPlscName
        properties: {
          privateLinkServiceId: stg.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource newPeDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: newPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file'
        properties: {
          privateDnsZoneId: effectiveDnsZoneId
        }
      }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================

output newPrivateEndpointId string = newPe.id
output newPrivateEndpointName string = newPe.name
output newPrivateEndpointIp string = length(newPe.properties.customDnsConfigs) > 0 && length(newPe.properties.customDnsConfigs[0].ipAddresses) > 0 ? newPe.properties.customDnsConfigs[0].ipAddresses[0] : 'pending'
output newDnsVnetLinkName string = createDnsLink ? newDnsVnetLink.name : ''
output effectiveDnsZoneId string = effectiveDnsZoneId

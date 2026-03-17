// ============================================================================
// Module: Storage Account Private Endpoint + Private DNS Zone (Azure Files)
// Deploys a Private Endpoint for the storage account's "file" sub-resource.
// Optionally creates a Private DNS Zone (privatelink.file.<storage-suffix>)
// and VNet link, or references an existing zone (e.g., from ArtifactsStorage).
// ============================================================================

@description('Resource ID of the storage account')
param storageAccountId string

@description('Name of the storage account (used for PE naming)')
param storageAccountName string

@description('Subnet resource ID for the private endpoint')
param subnetId string

@description('VNet resource ID to link the private DNS zone to')
param vnetId string

@description('Azure region')
param location string

@description('Tags')
param tags object = {}

@description('Resource ID of an existing privatelink.file DNS zone. When provided, the module skips DNS zone and VNet link creation and registers the PE in the existing zone.')
param existingPrivateDnsZoneId string = ''

// Build the zone name dynamically so it works in sovereign clouds
var privateDnsZoneName = 'privatelink.file.${environment().suffixes.storage}'
var createDnsZone = empty(existingPrivateDnsZoneId)

// ---------------------------------------------------------------------------
// Private DNS Zone: privatelink.file.<storage-suffix>
// Created only when no existing zone is provided.
// ---------------------------------------------------------------------------
resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (createDnsZone) {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

// Link the DNS zone to the lab VNet so VPN clients & VMs can resolve
resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (createDnsZone) {
  parent: dnsZone
  name: '${storageAccountName}-vnet-link'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

// Resolve the effective DNS zone ID — either the newly created zone or the existing one
var effectiveDnsZoneId = createDnsZone ? dnsZone.id : existingPrivateDnsZoneId

// ---------------------------------------------------------------------------
// Private Endpoint — targets storage account "file" sub-resource
// ---------------------------------------------------------------------------
resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${storageAccountName}-pe-file'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageAccountName}-plsc-file'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

// DNS Zone Group — auto-registers the PE IP as an A record in the private DNS zone
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: pe
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

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output privateEndpointId string = pe.id
output dnsZoneId string = effectiveDnsZoneId

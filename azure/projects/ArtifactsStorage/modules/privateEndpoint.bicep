// ============================================================================
// Module: Private Endpoint + Private DNS Zone for Azure Files
// Creates a PE targeting the storage account's "file" sub-resource, a private
// DNS zone (privatelink.file.core.windows.net), a VNet link, and a DNS zone
// group so the A record is auto-registered.
// ============================================================================

@description('Resource ID of the storage account')
param storageAccountId string

@description('Name of the storage account (used for PE naming)')
param storageAccountName string

@description('Subnet resource ID for the private endpoint')
param subnetId string

@description('VNet resource ID to link the private DNS zone to')
param vnetId string

@description('Display name for the VNet link in the private DNS zone')
param vnetLinkName string

@description('Azure region')
param location string

@description('Tags')
param tags object = {}

// Build the zone name dynamically so it works in sovereign clouds
var privateDnsZoneName = 'privatelink.file.${environment().suffixes.storage}'

// ---------------------------------------------------------------------------
// Private DNS Zone: privatelink.file.<storage-suffix>
// ---------------------------------------------------------------------------
resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

// Link the DNS zone to the lab VNet so VPN clients can resolve
resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZone
  name: vnetLinkName
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

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
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output privateEndpointId string = pe.id
output privateEndpointIp string = pe.properties.customDnsConfigs[0].ipAddresses[0]
output dnsZoneId string = dnsZone.id

// ============================================================================
// Module: Key Vault Private Endpoint + Private DNS Zone
// Deploys a Private Endpoint for the Key Vault "vault" sub-resource,
// a Private DNS Zone (privatelink.vaultcore.azure.net), VNet link,
// and DNS Zone Group for automatic A-record registration.
// ============================================================================

@description('Resource ID of the Key Vault')
param keyVaultId string

@description('Name of the Key Vault (used for PE naming)')
param keyVaultName string

@description('Subnet resource ID for the private endpoint')
param subnetId string

@description('VNet resource ID to link the private DNS zone to')
param vnetId string

@description('Azure region')
param location string

@description('Tags')
param tags object = {}

// Build the zone name dynamically for sovereign cloud compatibility
var privateDnsZoneName = 'privatelink.vaultcore.azure.net'

// ---------------------------------------------------------------------------
// Private DNS Zone: privatelink.vaultcore.azure.net
// ---------------------------------------------------------------------------
resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

// Link the DNS zone to the lab VNet so VPN clients & VMs can resolve
resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZone
  name: '${keyVaultName}-vnet-link'
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
// Private Endpoint — targets Key Vault "vault" sub-resource
// ---------------------------------------------------------------------------
resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${keyVaultName}-pe-vault'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${keyVaultName}-plsc-vault'
        properties: {
          privateLinkServiceId: keyVaultId
          groupIds: [
            'vault'
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
        name: 'privatelink-vault'
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

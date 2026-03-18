// ============================================================================
// Module: Key Vault Private Endpoint + Private DNS Zone
// Deploys a Private Endpoint for the Key Vault "vault" sub-resource.
// Optionally creates a Private DNS Zone (privatelink.vaultcore.azure.net)
// and VNet link, or references an existing zone.
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

@description('Resource ID of an existing privatelink.vaultcore DNS zone. When provided, the module skips DNS zone and VNet link creation and registers the PE in the existing zone.')
param existingPrivateDnsZoneId string = ''

// Build the zone name dynamically for sovereign cloud compatibility
var privateDnsZoneName = 'privatelink.vaultcore.azure.net'
var createDnsZone = empty(existingPrivateDnsZoneId)

// ---------------------------------------------------------------------------
// Private DNS Zone: privatelink.vaultcore.azure.net
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

// Resolve the effective DNS zone ID — either the newly created zone or the existing one
var effectiveDnsZoneId = createDnsZone ? dnsZone.id : existingPrivateDnsZoneId

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

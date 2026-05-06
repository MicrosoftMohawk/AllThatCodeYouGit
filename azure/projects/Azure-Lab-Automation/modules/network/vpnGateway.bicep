// ============================================================================
// Module: VPN Gateway with Point-to-Site (P2S) Certificate Authentication
// Deploys a VPN Gateway with a Public IP for remote access to the lab.
// NOTE: VPN Gateway provisioning typically takes 25-45 minutes.
// ============================================================================

@description('Name of the VPN Gateway')
param vpnGatewayName string

@description('Azure region')
param location string

@description('Resource ID of the GatewaySubnet')
param gatewaySubnetId string

@description('P2S VPN client address pool CIDR (must not overlap with VNet)')
param vpnClientAddressPrefix string = '172.16.0.0/24'

@description('Base64-encoded root certificate public key (.cer) — no headers/footers')
param rootCertData string

@description('Friendly name for the root certificate')
param rootCertName string = 'P2SRootCert'

@description('VPN Gateway SKU')
@allowed(['VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ'])
param gatewaySku string = 'VpnGw1AZ'

@description('Tags')
param tags object = {}

// ---------------------------------------------------------------------------
// Public IP for VPN Gateway
// ---------------------------------------------------------------------------
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vpnGatewayName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ---------------------------------------------------------------------------
// VPN Gateway — Route-based with P2S certificate auth
// ---------------------------------------------------------------------------
resource vpnGw 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: vpnGatewayName
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    sku: {
      name: gatewaySku
      tier: gatewaySku
    }
    enableBgp: false
    activeActive: false
    ipConfigurations: [
      {
        name: 'vpnGwIpConfig'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
          subnet: {
            id: gatewaySubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: {
        addressPrefixes: [
          vpnClientAddressPrefix
        ]
      }
      vpnClientProtocols: [
        'IkeV2'
        'SSTP'
      ]
      vpnAuthenticationTypes: [
        'Certificate'
      ]
      vpnClientRootCertificates: [
        {
          name: rootCertName
          properties: {
            publicCertData: rootCertData
          }
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output vpnGatewayId string = vpnGw.id
output vpnGatewayName string = vpnGw.name
output vpnPublicIp string = pip.properties.ipAddress

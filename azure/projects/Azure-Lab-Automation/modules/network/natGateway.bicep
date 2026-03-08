// ============================================================================
// Module: NAT Gateway
// Deploys a Standard SKU NAT Gateway with a Public IP for outbound internet
// access.  Associate the NAT Gateway ID with subnets that need egress.
// ============================================================================

@description('Name of the NAT Gateway resource')
param natGatewayName string

@description('Azure region')
param location string

@description('Tags')
param tags object = {}

@description('Idle timeout in minutes (4–120)')
@minValue(4)
@maxValue(120)
param idleTimeoutMinutes int = 4

// ---------------------------------------------------------------------------
// Public IP for NAT Gateway
// ---------------------------------------------------------------------------
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${natGatewayName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ---------------------------------------------------------------------------
// NAT Gateway
// ---------------------------------------------------------------------------
resource natGw 'Microsoft.Network/natGateways@2023-11-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: idleTimeoutMinutes
    publicIpAddresses: [
      {
        id: pip.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output natGatewayId string = natGw.id
output publicIpAddress string = pip.properties.ipAddress

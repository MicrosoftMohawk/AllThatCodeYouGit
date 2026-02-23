// ============================================================================
// Module: Azure Bastion
// Deploys Azure Bastion with a Standard-SKU Public IP for secure VM access
// ============================================================================

@description('Name of the Bastion host')
param bastionName string

@description('Azure region for deployment')
param location string

@description('Resource ID of the AzureBastionSubnet')
param subnetId string

@description('Tags to apply to all resources')
param tags object = {}

// ---------------------------------------------------------------------------
// Public IP for Bastion
// ---------------------------------------------------------------------------
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${bastionName}-pip'
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
// Azure Bastion Host
// ---------------------------------------------------------------------------
resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          publicIPAddress: {
            id: bastionPip.id
          }
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output bastionId string = bastion.id
output bastionName string = bastion.name

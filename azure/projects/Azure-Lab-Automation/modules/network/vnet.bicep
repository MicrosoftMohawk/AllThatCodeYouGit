// ============================================================================
// Module: Virtual Network with Subnets and NSGs
// Deploys the hub VNet, all subnets, and per-subnet Network Security Groups
// ============================================================================

@description('Name of the virtual network')
param vnetName string

@description('Azure region for deployment')
param location string

@description('VNet address space (CIDR)')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('AD subnet CIDR')
param snetAdPrefix string = '10.0.1.0/24'

@description('Azure Bastion subnet CIDR (must be /26 or larger)')
param snetBastionPrefix string = '10.0.0.0/26'

@description('Main site subnet CIDR (CAS, PrimA, SQL-CAS, SQL-PrimA)')
param snetMainPrefix string = '10.0.20.0/24'

@description('Site 1 subnet CIDR (PrimB, SQL-PrimB)')
param snetSite1Prefix string = '10.0.30.0/24'

@description('Site 2 subnet CIDR (PrimC, SQL-PrimC AOAG, ILB)')
param snetSite2Prefix string = '10.0.40.0/24'

@description('Tags to apply to all resources')
param tags object = {}

@description('Custom DNS server IP addresses for the VNet (e.g., DC static IPs). Leave empty to use Azure-provided DNS.')
param dnsServers array = []

@description('GatewaySubnet CIDR for VPN Gateway (/27 minimum). Leave empty to skip.')
param snetGatewayPrefix string = ''

// ---------------------------------------------------------------------------
// NSG: AD Subnet
// ---------------------------------------------------------------------------
resource nsgAd 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-ad'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: snetBastionPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG: Main Site Subnet
// ---------------------------------------------------------------------------
resource nsgMain 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-main'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: snetBastionPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG: Site 1 Subnet
// ---------------------------------------------------------------------------
resource nsgSite1 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-site1'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: snetBastionPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG: Site 2 Subnet
// ---------------------------------------------------------------------------
resource nsgSite2 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${vnetName}-nsg-site2'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Bastion-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: snetBastionPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-SQL-AOAG'
        properties: {
          priority: 300
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: snetSite2Prefix
          sourcePortRange: '*'
          destinationAddressPrefix: snetSite2Prefix
          destinationPortRange: '1433'
        }
      }
      {
        name: 'Allow-AOAG-Endpoint'
        properties: {
          priority: 310
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: snetSite2Prefix
          sourcePortRange: '*'
          destinationAddressPrefix: snetSite2Prefix
          destinationPortRange: '5022'
        }
      }
      {
        name: 'Allow-ILB-Probe'
        properties: {
          priority: 320
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '59999'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Network with all Subnets
// GatewaySubnet MUST be included inline so ARM doesn't try to delete it
// on redeployment (it cannot be removed while VPN Gateway is attached).
// ---------------------------------------------------------------------------

var baseSubnets = [
  {
    name: 'AzureBastionSubnet'
    properties: {
      addressPrefix: snetBastionPrefix
    }
  }
  {
    name: 'snet-ad'
    properties: {
      addressPrefix: snetAdPrefix
      networkSecurityGroup: {
        id: nsgAd.id
      }
    }
  }
  {
    name: 'snet-main'
    properties: {
      addressPrefix: snetMainPrefix
      networkSecurityGroup: {
        id: nsgMain.id
      }
    }
  }
  {
    name: 'snet-site1'
    properties: {
      addressPrefix: snetSite1Prefix
      networkSecurityGroup: {
        id: nsgSite1.id
      }
    }
  }
  {
    name: 'snet-site2'
    properties: {
      addressPrefix: snetSite2Prefix
      networkSecurityGroup: {
        id: nsgSite2.id
      }
    }
  }
]

var gatewaySubnetEntry = !empty(snetGatewayPrefix) ? [
  {
    name: 'GatewaySubnet'
    properties: {
      addressPrefix: snetGatewayPrefix
    }
  }
] : []

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    dhcpOptions: !empty(dnsServers) ? {
      dnsServers: dnsServers
    } : null
    subnets: concat(baseSubnets, gatewaySubnetEntry)
  }
}

// ---------------------------------------------------------------------------
// Outputs — subnet resource IDs for downstream modules
// ---------------------------------------------------------------------------
output vnetId string = vnet.id
output vnetName string = vnet.name
output snetBastionId string = vnet.properties.subnets[0].id
output snetAdId string = vnet.properties.subnets[1].id
output snetMainId string = vnet.properties.subnets[2].id
output snetSite1Id string = vnet.properties.subnets[3].id
output snetSite2Id string = vnet.properties.subnets[4].id
output snetGatewayId string = !empty(snetGatewayPrefix) ? vnet.properties.subnets[5].id : ''

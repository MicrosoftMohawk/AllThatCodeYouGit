// ============================================================================
// Module: Reusable Windows Server VM
// Deploys a NIC + Windows Server VM with optional static IP, data disks,
// availability set membership, and load balancer backend pool association.
// ============================================================================

@description('Name of the virtual machine (also used as computer name)')
@maxLength(15)
param vmName string

@description('Azure region for deployment')
param location string

@description('VM size SKU')
param vmSize string

@description('Resource ID of the subnet for the NIC')
param subnetId string

@description('Local admin username')
param adminUsername string

@description('Local admin password')
@secure()
param adminPassword string

@description('OS image publisher')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('OS image offer')
param imageOffer string = 'WindowsServer'

@description('OS image SKU')
param imageSku string = '2022-datacenter-g2'

@description('OS image version')
param imageVersion string = 'latest'

@description('Optional static private IP address. Leave empty for dynamic allocation.')
param privateIpAddress string = ''

@description('Number of data disks to attach (each 128 GB Premium SSD)')
@minValue(0)
@maxValue(4)
param dataDiskCount int = 0

@description('Size of each data disk in GB')
param dataDiskSizeGb int = 128

@description('Storage type for data disks')
@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Standard_LRS'
])
param dataDiskSku string = 'Premium_LRS'

@description('Storage type for the OS disk')
@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Standard_LRS'
])
param osDiskSku string = 'Premium_LRS'

@description('Optional: Availability Set resource ID')
param availabilitySetId string = ''

@description('Optional: Load Balancer backend address pool resource ID (for ILB association)')
param loadBalancerBackendPoolId string = ''

@description('Tags to apply to all resources')
param tags object = {}

// ---------------------------------------------------------------------------
// NIC
// ---------------------------------------------------------------------------
var nicName = '${vmName}-nic'
var useStaticIp = !empty(privateIpAddress)
var useLb = !empty(loadBalancerBackendPoolId)

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: useStaticIp ? 'Static' : 'Dynamic'
          privateIPAddress: useStaticIp ? privateIpAddress : null
          subnet: {
            id: subnetId
          }
          loadBalancerBackendAddressPools: useLb ? [
            {
              id: loadBalancerBackendPoolId
            }
          ] : []
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Data Disks (generated array)
// ---------------------------------------------------------------------------
var dataDisks = [for i in range(0, dataDiskCount): {
  name: '${vmName}-datadisk-${i}'
  lun: i
  createOption: 'Empty'
  diskSizeGB: dataDiskSizeGb
  managedDisk: {
    storageAccountType: dataDiskSku
  }
  caching: (i == 0) ? 'ReadOnly' : 'None' // first disk (data) = ReadOnly, second (log) = None
}]

// ---------------------------------------------------------------------------
// Virtual Machine
// ---------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    availabilitySet: !empty(availabilitySetId) ? {
      id: availabilitySetId
    } : null
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskSku
        }
        caching: 'ReadWrite'
        diskSizeGB: 128
      }
      dataDisks: dataDisks
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output vmId string = vm.id
output vmName string = vm.name
output nicId string = nic.id
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress

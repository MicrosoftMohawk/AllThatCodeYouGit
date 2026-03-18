// ============================================================================
// Management VM — Standalone Deployment (Resource-Group Scoped)
//
// Deploys the management VM with pure Entra ID join into the existing identity
// resource group created by the main lab deployment.
//
// Run AFTER the main lab deployment completes so that both DCs are online with
// DNS forwarders configured for public name resolution.
//
// Steps deployed (in order):
//   1. VM (Windows Server, AD subnet, static IP 10.0.1.7)
//   2. Entra DNS readiness check (polls until login.microsoftonline.com resolves)
//   3. AADLoginForWindows extension (pure Entra ID join)
//   4. RSAT + Az PowerShell + Azure CLI + SqlServer module
//   5. Virtual Machine Administrator Login RBAC (optional)
//
// Usage:
//   az deployment group create \
//     --resource-group <baseName>-rg-identity \
//     --template-file mgmt.bicep \
//     --parameters baseName=<baseName> location=<location> adminPassword=<pw>
// ============================================================================

// =============================================================================
// Parameters
// =============================================================================

@description('Base name prefix from the main lab deployment')
@maxLength(10)
param baseName string

@description('Azure region (must match the main lab deployment)')
param location string

@description('Local administrator username')
param adminUsername string = 'labadmin'

@description('Local administrator password (same as main lab deployment)')
@secure()
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_D2s_v5'

@description('Static IP for management VM (must be in AD subnet range)')
param privateIpAddress string = '10.0.1.7'

@description('Entra ID object ID of the user to grant VM Administrator Login RBAC (leave empty to skip)')
param deployerObjectId string = ''

@description('Principal type for RBAC assignment')
@allowed(['User', 'Group'])
param principalType string = 'User'

@description('Windows Server image publisher')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Windows Server image offer')
param imageOffer string = 'WindowsServer'

@description('Windows Server image SKU')
param imageSku string = '2022-datacenter-g2'

// =============================================================================
// Variables
// =============================================================================

var vmName = '${baseName}-mgmt'
var vnetName = '${baseName}-vnet'
var rgNetwork = '${baseName}-rg-network'

var commonTags = {
  env: 'lab'
  project: 'azure-lab'
  deployedBy: 'bicep'
}

// =============================================================================
// Existing Resources (from main lab deployment)
// =============================================================================

// Reference the AD subnet from the network RG
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: vnetName
  scope: resourceGroup(rgNetwork)
}

// AD subnet is index 1 in the VNet definition
var snetAdId = '${vnet.id}/subnets/snet-ad'

// =============================================================================
// Step 1: Deploy the VM
// =============================================================================

module mgmtVm 'modules/compute/vm.bicep' = {
  name: 'deploy-mgmt-vm'
  params: {
    vmName: vmName
    location: location
    vmSize: vmSize
    subnetId: snetAdId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    privateIpAddress: privateIpAddress
    tags: union(commonTags, { role: 'management-console' })
  }
}

// =============================================================================
// Step 2: Entra ID Join (DNS check + AADLoginForWindows)
// =============================================================================

module entraIdJoin 'modules/identity/entraIdJoin.bicep' = {
  name: 'deploy-entra-login-mgmt'
  dependsOn: [mgmtVm]
  params: {
    vmName: vmName
    location: location
    tags: union(commonTags, { role: 'entra-id-join' })
  }
}

// =============================================================================
// Step 3: Install Management Tools (RSAT, Az PowerShell, Azure CLI, SqlServer)
// =============================================================================

module installMgmtTools 'modules/identity/managementTools.bicep' = {
  name: 'deploy-mgmt-tools'
  dependsOn: [entraIdJoin]
  params: {
    vmName: vmName
    location: location
    tags: union(commonTags, { role: 'management-tools' })
  }
}

// =============================================================================
// Step 4: RBAC — Virtual Machine Administrator Login (optional)
// =============================================================================

module vmAdminLogin 'modules/identity/vmLoginRbac.bicep' = if (!empty(deployerObjectId)) {
  name: 'deploy-mgmt-vm-rbac'
  dependsOn: [mgmtVm]
  params: {
    vmName: vmName
    principalId: deployerObjectId
    principalType: principalType
  }
}

// =============================================================================
// Outputs
// =============================================================================

output vmName string = mgmtVm.outputs.vmName
output privateIpAddress string = mgmtVm.outputs.privateIpAddress

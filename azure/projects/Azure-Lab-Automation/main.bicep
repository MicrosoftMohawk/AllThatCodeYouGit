// ============================================================================
// Azure Global Lab — Main Orchestrator (Subscription-Scoped)
//
// Deploys a modular Azure lab environment across 3 tiers:
//   Tier 1: Core networking, AD Domain Controllers, Azure Bastion, Cloud Witness
//   Tier 2: SQL Server VMs (5 total) including AOAG pair at Site 2 with ILB
//   Tier 3: Application VMs (CAS + 3 child primaries)
//
// Usage:
//   az deployment sub create \
//     --location eastus \
//     --template-file main.bicep \
//     --parameters parameters/main.bicepparam
// ============================================================================

targetScope = 'subscription'

// =============================================================================
// Parameters
// =============================================================================

@description('Base name prefix for all resources (e.g., "azlab")')
@maxLength(10)
param baseName string

@description('Azure region for all resources')
param location string

@description('Deployment tier: 1 = Core/AD only, 2 = + SQL, 3 = + App servers (all)')
@allowed([1, 2, 3])
param deploymentTier int = 3

@description('Local administrator username for all VMs')
param adminUsername string = 'labadmin'

@description('Local administrator password for all VMs')
@secure()
param adminPassword string

@description('Active Directory domain name (e.g., azlab.local)')
param domainName string

@description('Azure AD object ID of the deploying user (for Key Vault RBAC)')
param deployerObjectId string = ''

@description('Principal type for Key Vault RBAC assignment (User or Group)')
@allowed(['User', 'Group'])
param kvPrincipalType string = 'User'

// --- VM Sizes ----------------------------------------------------------------

@description('VM size for Domain Controllers')
param sizeDC string = 'Standard_D2s_v5'

@description('VM size for CAS and Primary site servers')
param sizeApp string = 'Standard_D4s_v5'

@description('VM size for standalone SQL VMs (CAS, PrimA, PrimB)')
param sizeSQL string = 'Standard_D4s_v5'

@description('VM size for AOAG SQL VMs (Site 2 — PrimC)')
param sizeSQLAoag string = 'Standard_D8s_v5'

// --- Network CIDRs -----------------------------------------------------------

@description('VNet address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Azure Bastion subnet CIDR (/26 minimum)')
param snetBastionPrefix string = '10.0.0.0/26'

@description('AD / Domain Controller subnet CIDR')
param snetAdPrefix string = '10.0.1.0/24'

@description('Main site subnet CIDR (CAS, PrimA, SQL-CAS, SQL-PrimA)')
param snetMainPrefix string = '10.0.20.0/24'

@description('Site 1 subnet CIDR (PrimB, SQL-PrimB)')
param snetSite1Prefix string = '10.0.30.0/24'

@description('Site 2 subnet CIDR (PrimC, SQL-PrimC AOAG nodes, ILB)')
param snetSite2Prefix string = '10.0.40.0/24'

@description('GatewaySubnet CIDR for VPN Gateway (/27 minimum)')
param snetGatewayPrefix string = '10.0.255.0/27'

// --- VPN Gateway -------------------------------------------------------------

@description('Base64-encoded root certificate public key for P2S VPN authentication')
param vpnRootCertData string = ''

@description('P2S VPN client address pool CIDR (must not overlap with VNet)')
param vpnClientAddressPrefix string = '172.16.0.0/24'

// --- Static IPs --------------------------------------------------------------

@description('Static IP for DC01')
param dc01Ip string = '10.0.1.4'

@description('Static IP for DC02')
param dc02Ip string = '10.0.1.5'

@description('AOAG Listener IP (ILB frontend) in Site 2 subnet')
param aoagListenerIp string = '10.0.40.10'

// --- OS Image ----------------------------------------------------------------

@description('Windows Server image publisher')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Windows Server image offer')
param imageOffer string = 'WindowsServer'

@description('Windows Server image SKU')
param imageSku string = '2022-datacenter-g2'

// --- Tags --------------------------------------------------------------------

@description('Environment tag')
param envTag string = 'lab'

// =============================================================================
// Variables
// =============================================================================

// Resource group names
var rgNetwork = '${baseName}-rg-network'
var rgIdentity = '${baseName}-rg-identity'
var rgMain = '${baseName}-rg-main'
var rgSite1 = '${baseName}-rg-site1'
var rgSite2 = '${baseName}-rg-site2'

// Common tags
var commonTags = {
  env: envTag
  project: 'azure-lab'
  deployedBy: 'bicep'
}

// Derived AD values
var netbiosName = toUpper(split(domainName, '.')[0])

// VM names (max 15 chars for Windows computer name — baseName max 10 + dash + 4 suffix)
var dc01Name = '${baseName}-dc01'
var dc02Name = '${baseName}-dc02'
var sqlCasName = '${baseName}-sqcs'
var sqlPrimaName = '${baseName}-sqpa'
var sqlPrimbName = '${baseName}-sqpb'
var sqlPrimc01Name = '${baseName}-sqc1'
var sqlPrimc02Name = '${baseName}-sqc2'
var casName = '${baseName}-cas'
var primaName = '${baseName}-prma'
var primbName = '${baseName}-prmb'
var primcName = '${baseName}-prmc'

// =============================================================================
// Resource Groups (all tiers — created upfront for idempotency)
// =============================================================================

resource rgNet 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgNetwork
  location: location
  tags: union(commonTags, { workload: 'network' })
}

resource rgId 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgIdentity
  location: location
  tags: union(commonTags, { workload: 'identity' })
}

resource rgMainSite 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgMain
  location: location
  tags: union(commonTags, { workload: 'main-site' })
}

resource rgSite1Res 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgSite1
  location: location
  tags: union(commonTags, { workload: 'site1' })
}

resource rgSite2Res 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgSite2
  location: location
  tags: union(commonTags, { workload: 'site2-aoag' })
}

// =============================================================================
// TIER 1: Core Networking, AD, Bastion, Cloud Witness
// =============================================================================

// --- VNet & Subnets ----------------------------------------------------------

module vnet 'modules/network/vnet.bicep' = {
  name: 'deploy-vnet'
  scope: rgNet
  params: {
    vnetName: '${baseName}-vnet'
    location: location
    vnetAddressPrefix: vnetAddressPrefix
    snetBastionPrefix: snetBastionPrefix
    snetAdPrefix: snetAdPrefix
    snetMainPrefix: snetMainPrefix
    snetSite1Prefix: snetSite1Prefix
    snetSite2Prefix: snetSite2Prefix
    snetGatewayPrefix: snetGatewayPrefix
    dnsServers: [dc01Ip, dc02Ip]
    tags: union(commonTags, { workload: 'network' })
  }
}

// --- Azure Bastion -----------------------------------------------------------

module bastion 'modules/network/bastion.bicep' = {
  name: 'deploy-bastion'
  scope: rgNet
  params: {
    bastionName: '${baseName}-bastion'
    location: location
    subnetId: vnet.outputs.snetBastionId
    tags: union(commonTags, { workload: 'bastion' })
  }
}

// --- VPN Gateway (P2S with certificate auth) ---------------------------------

module vpnGateway 'modules/network/vpnGateway.bicep' = if (!empty(vpnRootCertData)) {
  name: 'deploy-vpn-gateway'
  scope: rgNet
  params: {
    vpnGatewayName: '${baseName}-vpngw'
    location: location
    gatewaySubnetId: vnet.outputs.snetGatewayId
    vpnClientAddressPrefix: vpnClientAddressPrefix
    rootCertData: vpnRootCertData
    rootCertName: 'P2SRootCert'
    tags: union(commonTags, { workload: 'vpn' })
  }
}

// --- Key Vault (stores VM admin password as a secret) ------------------------

module keyVault 'modules/security/keyVault.bicep' = {
  name: 'deploy-keyvault'
  scope: rgId
  params: {
    keyVaultName: '${baseName}-kv-${uniqueString(subscription().id, baseName)}'
    location: location
    adminPassword: adminPassword
    deployerObjectId: deployerObjectId
    kvPrincipalType: kvPrincipalType
    tags: union(commonTags, { workload: 'secrets' })
  }
}

// --- Cloud Witness Storage Account -------------------------------------------

module cloudWitness 'modules/storage/storageAccount.bicep' = {
  name: 'deploy-cloud-witness'
  scope: rgId
  params: {
    namePrefix: 'stgcw'
    location: location
    skuName: 'Standard_LRS'
    tags: union(commonTags, { workload: 'cloud-witness' })
  }
}

// --- Domain Controller VMs ---------------------------------------------------

module dc01 'modules/compute/vm.bicep' = {
  name: 'deploy-dc01'
  scope: rgId
  params: {
    vmName: dc01Name
    location: location
    vmSize: sizeDC
    subnetId: vnet.outputs.snetAdId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    privateIpAddress: dc01Ip
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

module dc02 'modules/compute/vm.bicep' = {
  name: 'deploy-dc02'
  scope: rgId
  params: {
    vmName: dc02Name
    location: location
    vmSize: sizeDC
    subnetId: vnet.outputs.snetAdId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    privateIpAddress: dc02Ip
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// --- Promote DC01 as first domain controller --------------------------------

module promoteDc01 'modules/identity/promoteDC.bicep' = {
  name: 'deploy-promote-dc01'
  scope: rgId
  dependsOn: [dc01]
  params: {
    vmName: dc01Name
    location: location
    domainName: domainName
    netbiosName: netbiosName
    dsrmPassword: adminPassword
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// --- Configure AD: OUs, Groups, Service Accounts, gMSA ----------------------

module configureAd 'modules/identity/configureAD.bicep' = {
  name: 'deploy-configure-ad'
  scope: rgId
  dependsOn: [promoteDc01]
  params: {
    vmName: dc01Name
    location: location
    domainName: domainName
    svcAccountPassword: adminPassword
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// --- Promote DC02 as replica domain controller -------------------------------

module promoteDc02 'modules/identity/replicaDC.bicep' = {
  name: 'deploy-promote-dc02'
  scope: rgId
  dependsOn: [dc02, promoteDc01]
  params: {
    vmName: dc02Name
    location: location
    domainName: domainName
    primaryDcIp: dc01Ip
    adminUsername: adminUsername
    adminPassword: adminPassword
    dsrmPassword: adminPassword
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// =============================================================================
// TIER 2: SQL Server VMs + AOAG Infrastructure
// =============================================================================

// --- Availability Set for Site 2 AOAG SQL nodes ------------------------------

module avsetSqlSite2 'modules/compute/availabilitySet.bicep' = if (deploymentTier >= 2) {
  name: 'deploy-avset-sql-site2'
  scope: rgSite2Res
  params: {
    name: '${baseName}-avset-sql-site2'
    location: location
    faultDomainCount: 2
    updateDomainCount: 5
    tags: union(commonTags, { workload: 'sql-aoag' })
  }
}

// --- Internal Load Balancer for AOAG Listener --------------------------------

module ilb 'modules/compute/loadBalancer.bicep' = if (deploymentTier >= 2) {
  name: 'deploy-ilb-aoag'
  scope: rgSite2Res
  params: {
    lbName: '${baseName}-ilb-aoag'
    location: location
    subnetId: vnet.outputs.snetSite2Id
    frontendIp: aoagListenerIp
    tags: union(commonTags, { workload: 'sql-aoag' })
  }
}

// --- SQL VM: CAS (Main Site) -------------------------------------------------

module sqlCas 'modules/compute/vm.bicep' = if (deploymentTier >= 2) {
  name: 'deploy-sql-cas'
  scope: rgMainSite
  params: {
    vmName: sqlCasName
    location: location
    vmSize: sizeSQL
    subnetId: vnet.outputs.snetMainId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: 2
    dataDiskSizeGb: 128
    dataDiskSku: 'Premium_LRS'
    tags: union(commonTags, { role: 'sql-server', site: 'main' })
  }
}

// --- SQL VM: Primary A (Main Site) -------------------------------------------

module sqlPrima 'modules/compute/vm.bicep' = if (deploymentTier >= 2) {
  name: 'deploy-sql-prima'
  scope: rgMainSite
  params: {
    vmName: sqlPrimaName
    location: location
    vmSize: sizeSQL
    subnetId: vnet.outputs.snetMainId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: 2
    dataDiskSizeGb: 128
    dataDiskSku: 'Premium_LRS'
    tags: union(commonTags, { role: 'sql-server', site: 'main' })
  }
}

// --- SQL VM: Primary B (Site 1) ----------------------------------------------

module sqlPrimb 'modules/compute/vm.bicep' = if (deploymentTier >= 2) {
  name: 'deploy-sql-primb'
  scope: rgSite1Res
  params: {
    vmName: sqlPrimbName
    location: location
    vmSize: sizeSQL
    subnetId: vnet.outputs.snetSite1Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: 2
    dataDiskSizeGb: 128
    dataDiskSku: 'Premium_LRS'
    tags: union(commonTags, { role: 'sql-server', site: 'site1' })
  }
}

// --- SQL VM: Primary C — AOAG Node 1 (Site 2) --------------------------------

module sqlPrimc01 'modules/compute/vm.bicep' = if (deploymentTier >= 2) {
  name: 'deploy-sql-primc01'
  scope: rgSite2Res
  params: {
    vmName: sqlPrimc01Name
    location: location
    vmSize: sizeSQLAoag
    subnetId: vnet.outputs.snetSite2Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: 2
    dataDiskSizeGb: 128
    dataDiskSku: 'Premium_LRS'
    availabilitySetId: avsetSqlSite2.outputs.availabilitySetId
    loadBalancerBackendPoolId: ilb.outputs.backendPoolId
    tags: union(commonTags, { role: 'sql-server-aoag', site: 'site2', aoagNode: '1' })
  }
}

// --- SQL VM: Primary C — AOAG Node 2 (Site 2) --------------------------------

module sqlPrimc02 'modules/compute/vm.bicep' = if (deploymentTier >= 2) {
  name: 'deploy-sql-primc02'
  scope: rgSite2Res
  params: {
    vmName: sqlPrimc02Name
    location: location
    vmSize: sizeSQLAoag
    subnetId: vnet.outputs.snetSite2Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: 2
    dataDiskSizeGb: 128
    dataDiskSku: 'Premium_LRS'
    availabilitySetId: avsetSqlSite2.outputs.availabilitySetId
    loadBalancerBackendPoolId: ilb.outputs.backendPoolId
    tags: union(commonTags, { role: 'sql-server-aoag', site: 'site2', aoagNode: '2' })
  }
}

// =============================================================================
// TIER 3: Application VMs (CAS + 3 Child Primaries)
// =============================================================================

// --- CAS Server (Main Site) --------------------------------------------------

module casVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-cas'
  scope: rgMainSite
  params: {
    vmName: casName
    location: location
    vmSize: sizeApp
    subnetId: vnet.outputs.snetMainId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    tags: union(commonTags, { role: 'cas', site: 'main' })
  }
}

// --- Child Primary A (Main Site) ---------------------------------------------

module primaVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-prima'
  scope: rgMainSite
  params: {
    vmName: primaName
    location: location
    vmSize: sizeApp
    subnetId: vnet.outputs.snetMainId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    tags: union(commonTags, { role: 'child-primary', site: 'main' })
  }
}

// --- Child Primary B (Site 1) ------------------------------------------------

module primbVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-primb'
  scope: rgSite1Res
  params: {
    vmName: primbName
    location: location
    vmSize: sizeApp
    subnetId: vnet.outputs.snetSite1Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    tags: union(commonTags, { role: 'child-primary', site: 'site1' })
  }
}

// --- Child Primary C (Site 2) ------------------------------------------------

module primcVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-primc'
  scope: rgSite2Res
  params: {
    vmName: primcName
    location: location
    vmSize: sizeApp
    subnetId: vnet.outputs.snetSite2Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    tags: union(commonTags, { role: 'child-primary', site: 'site2' })
  }
}

// =============================================================================
// Outputs
// =============================================================================

output resourceGroups object = {
  network: rgNetwork
  identity: rgIdentity
  main: rgMain
  site1: rgSite1
  site2: rgSite2
}

output vnetId string = vnet.outputs.vnetId
output bastionName string = bastion.outputs.bastionName
output cloudWitnessStorageAccount string = cloudWitness.outputs.storageAccountName
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultSecretName string = keyVault.outputs.secretName

output dc01PrivateIp string = dc01.outputs.privateIpAddress
output dc02PrivateIp string = dc02.outputs.privateIpAddress

output vpnGatewayName string = !empty(vpnRootCertData) ? vpnGateway.outputs.vpnGatewayName : 'not-deployed'

output deploymentTierDeployed int = deploymentTier

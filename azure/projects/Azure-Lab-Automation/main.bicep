// ============================================================================
// Azure Global Lab — Main Orchestrator (Subscription-Scoped)
//
// Deploys a modular Azure lab environment across 3 tiers:
//   Tier 1: Core networking, AD Domain Controllers, Azure Bastion
//          Optional: Entra Connect Sync + Management VM (hybrid identity)
//   Tier 2: SQL Server VMs (one per site: CAS, PrimA, PrimB, PrimC)
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

// --- Entra ID Integration (Hybrid Identity) ---------------------------------

@description('Enable Entra ID hybrid identity integration (Entra Connect Sync, Management VM with Entra ID login)')
param enableEntraIntegration bool = false

@description('Entra ID tenant domain (e.g., usaavd.com). Required when enableEntraIntegration is true.')
param entraIdDomain string = ''

@description('AD domain naming strategy: subdomain = AD domain is ad.{entraIdDomain}, independent = AD domain is separate with UPN suffix added')
@allowed(['subdomain', 'independent'])
param domainStrategy string = 'subdomain'

@description('Where to install Entra Connect: dedicated = new VM, dc02 = install on DC02')
@allowed(['dedicated', 'dc02'])
param entraConnectPlacement string = 'dedicated'

@description('VM name: Entra Connect Sync Server')
@maxLength(15)
param vmNameEntraConnect string = '${baseName}-entr'

// --- VM Sizes ----------------------------------------------------------------

@description('VM size for Domain Controllers')
param sizeDC string = 'Standard_D2s_v6'

@description('VM size for Management and Entra Connect VMs')
param sizeManagement string = 'Standard_D2s_v6'

@description('VM size for MCM site servers (when SQL is separate)')
param sizeApp string = 'Standard_D4s_v6'

@description('VM size for MCM site servers when SQL is colocated (needs more RAM/CPU)')
param sizeAppColocated string = 'Standard_D8s_v6'

@description('VM size for standalone SQL VMs (CAS, PrimA, PrimB, PrimC)')
param sizeSQL string = 'Standard_D4s_v6'

// --- Disk SKUs ---------------------------------------------------------------

@description('OS disk storage type for all VMs')
@allowed(['Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS'])
param osDiskSku string = 'Premium_LRS'

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

@description('Site 2 subnet CIDR (PrimC, SQL-PrimC)')
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

@description('Static IP for Entra Connect server')
param entraConnectIp string = '10.0.1.6'

@description('Static IP for DC in Main site subnet')
param dcMainIp string = '10.0.20.250'

@description('Static IP for DC in Site 1 subnet')
param dcSite1Ip string = '10.0.30.250'

@description('Static IP for DC in Site 2 subnet')
param dcSite2Ip string = '10.0.40.250'

// --- Private DNS Zone Reuse --------------------------------------------------

@description('Resource ID of an existing privatelink.vaultcore DNS zone. When provided, the Key Vault PE skips DNS zone and VNet link creation to avoid conflicts.')
param existingKvDnsZoneId string = ''

// --- Colocated SQL+MCM option -------------------------------------------------

@description('When true, SQL is installed on the MCM server (no separate SQL VMs for CAS/PrimA/PrimB/PrimC).')
param colocateSql bool = false

@description('When true, SQL and MCM VMs are automatically domain-joined after deployment using the svc-domjoin service account.')
param joinDomain bool = true

// --- VM Naming ---------------------------------------------------------------
// Defaults follow baseName-suffix convention (max 15 chars for Windows).
// Override via parameters to use your own naming convention.

@description('VM name: SQL for CAS site (ignored when colocateSql=true)')
@maxLength(15)
param vmNameSqlCas string = '${baseName}-sqcs'

@description('VM name: SQL for Primary A (ignored when colocateSql=true)')
@maxLength(15)
param vmNameSqlPrimA string = '${baseName}-sqpa'

@description('VM name: SQL for Primary B (ignored when colocateSql=true)')
@maxLength(15)
param vmNameSqlPrimB string = '${baseName}-sqpb'

@description('VM name: SQL for Primary C at Site 2 (ignored when colocateSql=true)')
@maxLength(15)
param vmNameSqlPrimC string = '${baseName}-sqpc'

@description('VM name: CAS (Central Administration Site)')
@maxLength(15)
param vmNameCas string = '${baseName}-cas'

@description('VM name: Child Primary A (Main site)')
@maxLength(15)
param vmNamePrimA string = '${baseName}-prma'

@description('VM name: Child Primary B (Site 1)')
@maxLength(15)
param vmNamePrimB string = '${baseName}-prmb'

@description('VM name: Child Primary C (Site 2)')
@maxLength(15)
param vmNamePrimC string = '${baseName}-prmc'

// --- Site DC VM Names --------------------------------------------------------

@description('VM name: Domain Controller for Main site')
@maxLength(15)
param vmNameDcMain string = '${baseName}-dc03'

@description('VM name: Domain Controller for Site 1')
@maxLength(15)
param vmNameDcSite1 string = '${baseName}-dc04'

@description('VM name: Domain Controller for Site 2')
@maxLength(15)
param vmNameDcSite2 string = '${baseName}-dc05'

// --- OS Image ----------------------------------------------------------------

@description('Windows Server image publisher')
param imagePublisher string = 'MicrosoftWindowsServer'

@description('Windows Server image offer')
param imageOffer string = 'WindowsServer'

@description('Windows Server image SKU. Minimum supported is Server 2022; default is Server 2025 (Gen2).')
@allowed([
  '2022-datacenter-g2'
  '2025-datacenter-g2'
])
param imageSku string = '2025-datacenter-g2'

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

// Build the AD distinguished name (e.g., 'army.ic.lab' → 'DC=army,DC=ic,DC=lab')
var domainParts = split(domainName, '.')
var domainDN = join(map(domainParts, part => 'DC=${part}'), ',')

// VM names — DCs are always baseName + suffix; MCM/SQL names come from parameters
var dc01Name = '${baseName}-dc01'
var dc02Name = '${baseName}-dc02'
var dcMainName = vmNameDcMain
var dcSite1Name = vmNameDcSite1
var dcSite2Name = vmNameDcSite2

// Effective MCM VM size — upsize when SQL is colocated
var effectiveAppSize = colocateSql ? sizeAppColocated : sizeApp

// Domain join credential — uses svc-domjoin created by configureAD.bicep
var domainJoinUser = 'svc-domjoin@${domainName}'

// Entra integration — deploy Entra Connect VM only in dedicated placement mode
var deployEntraConnectVm = enableEntraIntegration && entraConnectPlacement == 'dedicated'
// Entra Connect target VM name (dedicated VM or DC02)
var entraConnectTargetVm = entraConnectPlacement == 'dedicated' ? vmNameEntraConnect : dc02Name

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
  tags: union(commonTags, { workload: 'site2' })
}

// =============================================================================
// TIER 1: Core Networking, AD, Bastion
// =============================================================================

// --- VNet & Subnets ----------------------------------------------------------

module natGateway 'modules/network/natGateway.bicep' = {
  name: 'deploy-natgw'
  scope: rgNet
  params: {
    natGatewayName: '${baseName}-natgw'
    location: location
    tags: union(commonTags, { workload: 'network' })
  }
}

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
    natGatewayId: natGateway.outputs.natGatewayId
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
    rootCertName: 'P2SRootCert-${baseName}'
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

// --- Key Vault Private Endpoint (disables public access) ---------------------

module keyVaultPe 'modules/security/keyVaultPrivateEndpoint.bicep' = {
  name: 'deploy-keyvault-pe'
  scope: rgNet
  params: {
    keyVaultId: keyVault.outputs.keyVaultId
    keyVaultName: keyVault.outputs.keyVaultName
    subnetId: vnet.outputs.snetPeId
    vnetId: vnet.outputs.vnetId
    existingPrivateDnsZoneId: existingKvDnsZoneId
    location: location
    tags: union(commonTags, { workload: 'secrets' })
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
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dc02Ip]
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
    osDiskSku: osDiskSku
    dnsServers: [dc02Ip, dc01Ip]
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// --- Site Domain Controller VMs (one per site for AD Sites & Services) -------

module dcMain 'modules/compute/vm.bicep' = {
  name: 'deploy-dc-main'
  scope: rgMainSite
  params: {
    vmName: dcMainName
    location: location
    vmSize: sizeDC
    subnetId: vnet.outputs.snetMainId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    privateIpAddress: dcMainIp
    osDiskSku: osDiskSku
    dnsServers: [dcMainIp, dc01Ip]
    tags: union(commonTags, { role: 'domain-controller', site: 'main' })
  }
}

module dcSite1 'modules/compute/vm.bicep' = {
  name: 'deploy-dc-site1'
  scope: rgSite1Res
  params: {
    vmName: dcSite1Name
    location: location
    vmSize: sizeDC
    subnetId: vnet.outputs.snetSite1Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    privateIpAddress: dcSite1Ip
    osDiskSku: osDiskSku
    dnsServers: [dcSite1Ip, dc01Ip]
    tags: union(commonTags, { role: 'domain-controller', site: 'site1' })
  }
}

module dcSite2 'modules/compute/vm.bicep' = {
  name: 'deploy-dc-site2'
  scope: rgSite2Res
  params: {
    vmName: dcSite2Name
    location: location
    vmSize: sizeDC
    subnetId: vnet.outputs.snetSite2Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    privateIpAddress: dcSite2Ip
    osDiskSku: osDiskSku
    dnsServers: [dcSite2Ip, dc01Ip]
    tags: union(commonTags, { role: 'domain-controller', site: 'site2' })
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
    selfIp: dc01Ip
    secondaryDcIp: dc02Ip
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// --- Promote replica DCs SEQUENTIALLY: DC02 -> DC03 -> DC04 -> DC05 ----------
// Chained via dependsOn so only ONE replica promotes at a time. Promoting all
// replicas concurrently against a freshly promoted DC01 caused the remote-site
// DCs (DC04/DC05) to fail promotion (DNS / DC-locator race) while the extension
// still reported success. Sequencing lets each DC fully promote, reboot, and
// replicate before the next one begins.

module promoteDcMain 'modules/identity/replicaDC.bicep' = {
  name: 'deploy-promote-dc-main'
  scope: rgMainSite
  dependsOn: [dcMain, promoteDc02]
  params: {
    vmName: dcMainName
    location: location
    domainName: domainName
    primaryDcIp: dc01Ip
    adminUsername: adminUsername
    adminPassword: adminPassword
    dsrmPassword: adminPassword
    selfIp: dcMainIp
    tags: union(commonTags, { role: 'domain-controller', site: 'main' })
  }
}

module promoteDcSite1 'modules/identity/replicaDC.bicep' = {
  name: 'deploy-promote-dc-site1'
  scope: rgSite1Res
  dependsOn: [dcSite1, promoteDcMain]
  params: {
    vmName: dcSite1Name
    location: location
    domainName: domainName
    primaryDcIp: dc01Ip
    adminUsername: adminUsername
    adminPassword: adminPassword
    dsrmPassword: adminPassword
    selfIp: dcSite1Ip
    tags: union(commonTags, { role: 'domain-controller', site: 'site1' })
  }
}

module promoteDcSite2 'modules/identity/replicaDC.bicep' = {
  name: 'deploy-promote-dc-site2'
  scope: rgSite2Res
  dependsOn: [dcSite2, promoteDcSite1]
  params: {
    vmName: dcSite2Name
    location: location
    domainName: domainName
    primaryDcIp: dc01Ip
    adminUsername: adminUsername
    adminPassword: adminPassword
    dsrmPassword: adminPassword
    selfIp: dcSite2Ip
    tags: union(commonTags, { role: 'domain-controller', site: 'site2' })
  }
}

// --- Configure AD: OUs, Groups, Service Accounts, gMSA, Sites & Services ----

module configureAd 'modules/identity/configureAD.bicep' = {
  name: 'deploy-configure-ad'
  scope: rgId
  dependsOn: [promoteDc01, promoteDc02, promoteDcMain, promoteDcSite1, promoteDcSite2]
  params: {
    vmName: dc01Name
    location: location
    domainName: domainName
    svcAccountPassword: adminPassword
    entraIdDomain: entraIdDomain
    domainStrategy: domainStrategy
    baseName: baseName
    snetAdPrefix: snetAdPrefix
    snetMainPrefix: snetMainPrefix
    snetSite1Prefix: snetSite1Prefix
    snetSite2Prefix: snetSite2Prefix
    dcMainName: dcMainName
    dcSite1Name: dcSite1Name
    dcSite2Name: dcSite2Name
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// --- Entra Connect Sync Server (dedicated VM, Tier 1) ------------------------

module entraConnectVm 'modules/compute/vm.bicep' = if (deployEntraConnectVm) {
  name: 'deploy-entra-connect'
  scope: rgId
  params: {
    vmName: vmNameEntraConnect
    location: location
    vmSize: sizeManagement
    subnetId: vnet.outputs.snetAdId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    privateIpAddress: entraConnectIp
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dc02Ip]
    tags: union(commonTags, { role: 'entra-connect' })
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
    selfIp: dc02Ip
    tags: union(commonTags, { role: 'domain-controller' })
  }
}

// --- Domain Join: Entra Connect VM (always joined -- Entra Connect requires AD membership)

module djEntraConnect 'modules/identity/domainJoin.bicep' = if (deployEntraConnectVm) {
  name: 'deploy-dj-entra-connect'
  scope: rgId
  dependsOn: [entraConnectVm, configureAd, promoteDc02]
  params: {
    vmName: vmNameEntraConnect
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=App Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

// --- Install Entra Connect Sync on target VM ---------------------------------

module installEntraConnect 'modules/identity/entraConnect.bicep' = if (enableEntraIntegration) {
  name: 'deploy-install-entra-connect'
  scope: rgId
  dependsOn: deployEntraConnectVm ? [djEntraConnect] : [promoteDc02]
  params: {
    vmName: entraConnectTargetVm
    location: location
    tags: union(commonTags, { role: 'entra-connect' })
  }
}

// =============================================================================
// TIER 2: SQL Server VMs
// =============================================================================

// --- SQL VM: CAS (Main Site) — skipped when colocateSql is true --------------

module sqlCas 'modules/compute/vm.bicep' = if (deploymentTier >= 2 && !colocateSql) {
  name: 'deploy-sql-cas'
  scope: rgMainSite
  params: {
    vmName: vmNameSqlCas
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
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcMainIp]
    tags: union(commonTags, { role: 'sql-server', site: 'main' })
  }
}

// --- SQL VM: Primary A (Main Site) — skipped when colocateSql is true --------

module sqlPrima 'modules/compute/vm.bicep' = if (deploymentTier >= 2 && !colocateSql) {
  name: 'deploy-sql-prima'
  scope: rgMainSite
  params: {
    vmName: vmNameSqlPrimA
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
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcMainIp]
    tags: union(commonTags, { role: 'sql-server', site: 'main' })
  }
}

// --- SQL VM: Primary B (Site 1) — skipped when colocateSql is true -----------

module sqlPrimb 'modules/compute/vm.bicep' = if (deploymentTier >= 2 && !colocateSql) {
  name: 'deploy-sql-primb'
  scope: rgSite1Res
  params: {
    vmName: vmNameSqlPrimB
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
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcSite1Ip]
    tags: union(commonTags, { role: 'sql-server', site: 'site1' })
  }
}

// --- SQL VM: Primary C (Site 2) — skipped when colocateSql is true -----------

module sqlPrimc 'modules/compute/vm.bicep' = if (deploymentTier >= 2 && !colocateSql) {
  name: 'deploy-sql-primc'
  scope: rgSite2Res
  params: {
    vmName: vmNameSqlPrimC
    location: location
    vmSize: sizeSQL
    subnetId: vnet.outputs.snetSite2Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: 2
    dataDiskSizeGb: 128
    dataDiskSku: 'Premium_LRS'
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcSite2Ip]
    tags: union(commonTags, { role: 'sql-server', site: 'site2' })
  }
}

// --- Domain Join: SQL VMs (Tier 2) ------------------------------------------

module djSqlCas 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 2 && !colocateSql && joinDomain) {
  name: 'deploy-dj-sql-cas'
  scope: rgMainSite
  dependsOn: [sqlCas, configureAd, promoteDc02]
  params: {
    vmName: vmNameSqlCas
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=SQL Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

module djSqlPrimA 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 2 && !colocateSql && joinDomain) {
  name: 'deploy-dj-sql-prima'
  scope: rgMainSite
  dependsOn: [sqlPrima, configureAd, promoteDc02]
  params: {
    vmName: vmNameSqlPrimA
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=SQL Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

module djSqlPrimB 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 2 && !colocateSql && joinDomain) {
  name: 'deploy-dj-sql-primb'
  scope: rgSite1Res
  dependsOn: [sqlPrimb, configureAd, promoteDc02]
  params: {
    vmName: vmNameSqlPrimB
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=SQL Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

module djSqlPrimC 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 2 && !colocateSql && joinDomain) {
  name: 'deploy-dj-sql-primc'
  scope: rgSite2Res
  dependsOn: [sqlPrimc, configureAd, promoteDc02]
  params: {
    vmName: vmNameSqlPrimC
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=SQL Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

// =============================================================================
// TIER 3: Application VMs (CAS + 3 Child Primaries)
// When colocateSql=true, MCM VMs get data disks and are upsized for SQL.
// =============================================================================

// --- CAS Server (Main Site) --------------------------------------------------

module casVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-cas'
  scope: rgMainSite
  params: {
    vmName: vmNameCas
    location: location
    vmSize: effectiveAppSize
    subnetId: vnet.outputs.snetMainId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: colocateSql ? 2 : 0
    dataDiskSizeGb: colocateSql ? 128 : 0
    dataDiskSku: colocateSql ? 'Premium_LRS' : 'Standard_LRS'
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcMainIp]
    tags: union(commonTags, { role: colocateSql ? 'cas-sql' : 'cas', site: 'main' })
  }
}

// --- Child Primary A (Main Site) ---------------------------------------------

module primaVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-prima'
  scope: rgMainSite
  params: {
    vmName: vmNamePrimA
    location: location
    vmSize: effectiveAppSize
    subnetId: vnet.outputs.snetMainId
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: colocateSql ? 2 : 0
    dataDiskSizeGb: colocateSql ? 128 : 0
    dataDiskSku: colocateSql ? 'Premium_LRS' : 'Standard_LRS'
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcMainIp]
    tags: union(commonTags, { role: colocateSql ? 'child-primary-sql' : 'child-primary', site: 'main' })
  }
}

// --- Child Primary B (Site 1) ------------------------------------------------

module primbVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-primb'
  scope: rgSite1Res
  params: {
    vmName: vmNamePrimB
    location: location
    vmSize: effectiveAppSize
    subnetId: vnet.outputs.snetSite1Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: colocateSql ? 2 : 0
    dataDiskSizeGb: colocateSql ? 128 : 0
    dataDiskSku: colocateSql ? 'Premium_LRS' : 'Standard_LRS'
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcSite1Ip]
    tags: union(commonTags, { role: colocateSql ? 'child-primary-sql' : 'child-primary', site: 'site1' })
  }
}

// --- Child Primary C (Site 2) ------------------------------------------------

module primcVm 'modules/compute/vm.bicep' = if (deploymentTier >= 3) {
  name: 'deploy-primc'
  scope: rgSite2Res
  params: {
    vmName: vmNamePrimC
    location: location
    vmSize: effectiveAppSize
    subnetId: vnet.outputs.snetSite2Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    dataDiskCount: colocateSql ? 2 : 0
    dataDiskSizeGb: colocateSql ? 128 : 0
    dataDiskSku: colocateSql ? 'Premium_LRS' : 'Standard_LRS'
    osDiskSku: osDiskSku
    dnsServers: [dc01Ip, dcSite2Ip]
    tags: union(commonTags, { role: colocateSql ? 'child-primary-sql' : 'child-primary', site: 'site2' })
  }
}

// --- Domain Join: MCM VMs (Tier 3) ------------------------------------------

module djCas 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 3 && joinDomain) {
  name: 'deploy-dj-cas'
  scope: rgMainSite
  dependsOn: [casVm, configureAd, promoteDc02]
  params: {
    vmName: vmNameCas
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=App Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

module djPrimA 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 3 && joinDomain) {
  name: 'deploy-dj-prima'
  scope: rgMainSite
  dependsOn: [primaVm, configureAd, promoteDc02]
  params: {
    vmName: vmNamePrimA
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=App Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

module djPrimB 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 3 && joinDomain) {
  name: 'deploy-dj-primb'
  scope: rgSite1Res
  dependsOn: [primbVm, configureAd, promoteDc02]
  params: {
    vmName: vmNamePrimB
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=App Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
  }
}

module djPrimC 'modules/identity/domainJoin.bicep' = if (deploymentTier >= 3 && joinDomain) {
  name: 'deploy-dj-primc'
  scope: rgSite2Res
  dependsOn: [primcVm, configureAd, promoteDc02]
  params: {
    vmName: vmNamePrimC
    location: location
    domainName: domainName
    domainJoinUser: domainJoinUser
    domainJoinPassword: adminPassword
    ouPath: 'OU=App Servers,OU=Lab Servers,${domainDN}'
    tags: union(commonTags, { role: 'domain-join' })
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
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultSecretName string = keyVault.outputs.secretName

output dc01PrivateIp string = dc01.outputs.privateIpAddress
output dc02PrivateIp string = dc02.outputs.privateIpAddress

output vpnGatewayName string = !empty(vpnRootCertData) ? vpnGateway.outputs.vpnGatewayName : 'not-deployed'

output deploymentTierDeployed int = deploymentTier
output entraIntegrationEnabled bool = enableEntraIntegration
output entraConnectVmName string = deployEntraConnectVm ? entraConnectVm.outputs.vmName : (enableEntraIntegration ? dc02Name : 'not-deployed')

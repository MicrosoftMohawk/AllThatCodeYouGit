// ============================================================================
// Module: Configure Active Directory
// Uses VM RunCommand to create OUs, security groups, service accounts, gMSA,
// configure AD Sites and Services, and delegate domain-join permissions.
// Runs on DC01 after forest promotion.
// ============================================================================

@description('Name of the DC VM to run configuration on')
param vmName string

@description('Azure region')
param location string

@description('Fully qualified domain name')
param domainName string

@description('Password for service accounts')
@secure()
param svcAccountPassword string

@description('Entra ID tenant domain for UPN suffix (empty to skip)')
param entraIdDomain string = ''

@description('Domain strategy: subdomain or independent')
param domainStrategy string = 'subdomain'

@description('Base name prefix for AD site naming')
param baseName string

@description('AD / Identity subnet CIDR')
param snetAdPrefix string

@description('Main site subnet CIDR')
param snetMainPrefix string

@description('Site 1 subnet CIDR')
param snetSite1Prefix string

@description('Site 2 subnet CIDR')
param snetSite2Prefix string

@description('VM name of the DC deployed to Main site subnet')
param dcMainName string

@description('VM name of the DC deployed to Site 1 subnet')
param dcSite1Name string

@description('VM name of the DC deployed to Site 2 subnet')
param dcSite2Name string

@description('Tags')
param tags object = {}

// ---------------------------------------------------------------------------
// VM RunCommand — configure AD objects after DC promotion
// RunCommand can coexist with CustomScriptExtension on the same VM.
// ---------------------------------------------------------------------------
resource configureAD 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  name: '${vmName}/ConfigureAD'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 900
    source: {
      script: loadTextContent('scripts/Configure-AD.ps1')
    }
    protectedParameters: [
      {
        name: 'SvcPassword'
        value: svcAccountPassword
      }
    ]
    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'EntraIdDomain'
        value: entraIdDomain
      }
      {
        name: 'DomainStrategy'
        value: domainStrategy
      }
      {
        name: 'BaseName'
        value: baseName
      }
      {
        name: 'SnetAdPrefix'
        value: snetAdPrefix
      }
      {
        name: 'SnetMainPrefix'
        value: snetMainPrefix
      }
      {
        name: 'SnetSite1Prefix'
        value: snetSite1Prefix
      }
      {
        name: 'SnetSite2Prefix'
        value: snetSite2Prefix
      }
      {
        name: 'DcMainName'
        value: dcMainName
      }
      {
        name: 'DcSite1Name'
        value: dcSite1Name
      }
      {
        name: 'DcSite2Name'
        value: dcSite2Name
      }
    ]
  }
}

output runCommandId string = configureAD.id

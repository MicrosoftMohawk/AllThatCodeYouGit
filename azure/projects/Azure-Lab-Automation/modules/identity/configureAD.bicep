// ============================================================================
// Module: Configure Active Directory
// Uses VM RunCommand to create OUs, security groups, service accounts, gMSA,
// and delegate domain-join permissions. Runs on DC01 after forest promotion.
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
    ]
  }
}

output runCommandId string = configureAD.id

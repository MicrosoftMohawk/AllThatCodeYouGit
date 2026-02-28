// ============================================================================
// Module: Domain Join — Join a Windows VM to an Active Directory domain
//
// Uses the JsonADDomainExtension (Microsoft.Compute.JsonADDomainExtension)
// to join the target VM to the specified AD domain.
//
// Prerequisites:
//   - The domain must be reachable from the VM's subnet (VNet DNS set to DCs).
//   - The join credential must have permission to create computer objects
//     (e.g., the svc-domjoin account created by configureAD.bicep).
//
// By default the VM is joined to the default Computers container. To place it
// in a specific OU, set the ouPath parameter.
// ============================================================================

@description('Name of the existing VM to domain-join')
param vmName string

@description('Azure region')
param location string

@description('Fully qualified domain name (e.g., azlab.local)')
param domainName string

@description('UPN or DOMAIN\\user with permission to join machines to the domain')
param domainJoinUser string

@description('Password for the domain join account')
@secure()
param domainJoinPassword string

@description('Optional OU path for the computer object (e.g., OU=SQL Servers,OU=Lab Servers,DC=azlab,DC=local). Leave empty for default Computers container.')
param ouPath string = ''

@description('Tags')
param tags object = {}

// Domain join options bitmask:
//   0x00000001 = Join domain
//   0x00000002 = Account create (create the computer account if it doesn't exist)
// Combined = 3
var domainJoinOptions = 3

resource domainJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: '${vmName}/JoinDomain'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      OUPath: ouPath
      User: domainJoinUser
      Restart: 'true'
      Options: domainJoinOptions
    }
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
}

output extensionId string = domainJoinExtension.id

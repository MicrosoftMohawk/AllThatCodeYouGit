// ============================================================================
// Module: Entra Connect Sync — Install on target VM
//
// Uses VM RunCommand to download and silently install Microsoft Entra Connect
// Sync on the specified VM. The VM must be domain-joined before this runs.
//
// The Entra Connect configuration wizard must be completed manually via
// RDP/Bastion after deployment. The wizard requires interactive Entra ID
// Global Administrator authentication which cannot be automated.
//
// Prerequisites:
//   - Target VM must be domain-joined and can reach the internet (NAT GW)
//   - Entra ID tenant with Azure AD P2 license
//   - Global Administrator credentials (for manual wizard step)
// ============================================================================

@description('Name of the VM to install Entra Connect on')
param vmName string

@description('Azure region')
param location string

@description('Tags')
param tags object = {}

// ---------------------------------------------------------------------------
// VM RunCommand — download and install Entra Connect
// ---------------------------------------------------------------------------
resource installEntraConnect 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  name: '${vmName}/InstallEntraConnect'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 900
    source: {
      script: loadTextContent('scripts/Install-EntraConnect.ps1')
    }
  }
}

output runCommandId string = installEntraConnect.id

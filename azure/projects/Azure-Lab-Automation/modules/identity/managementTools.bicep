// ============================================================================
// Module: Install Management Tools
// Uses VM RunCommand to install RSAT, Az PowerShell, Azure CLI, and SqlServer
// module on the management VM.
// ============================================================================

@description('Name of the VM to install management tools on')
param vmName string

@description('Azure region')
param location string

@description('Tags')
param tags object = {}

// ---------------------------------------------------------------------------
// VM RunCommand — install management tools
// ---------------------------------------------------------------------------
resource installTools 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  name: '${vmName}/InstallManagementTools'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 1800
    source: {
      script: loadTextContent('scripts/Install-ManagementTools.ps1')
    }
  }
}

output runCommandId string = installTools.id

// ============================================================================
// Module: Promote First Domain Controller (New Forest)
// Uses CustomScriptExtension to install AD DS role and promote as first DC.
// The VM reboots automatically after forest promotion.
// Idempotent: skips promotion if the NTDS service is already running.
// ============================================================================

@description('Name of the existing VM to promote')
param vmName string

@description('Azure region')
param location string

@description('Fully qualified domain name (e.g., azlab.local)')
param domainName string

@description('NetBIOS domain name (e.g., AZLAB)')
param netbiosName string

@description('DSRM safe-mode administrator password')
@secure()
param dsrmPassword string

@description('Tags')
param tags object = {}

// Workaround: Bicep parser has issues with ''${...}'' (escaped quote + interpolation).
// Use a variable containing a single-quote character and interpolate it instead.
var q = '\''

// ---------------------------------------------------------------------------
// CustomScriptExtension — install AD DS and promote as first DC
// Uses protectedSettings so the DSRM password is not exposed in logs.
// ---------------------------------------------------------------------------
resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: '${vmName}/PromoteFirstDC'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Bypass -Command "Start-Transcript -Path C:\\WindowsTemp\\PromoteDC1.log -Append; Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -IncludeAllSubFeature; if (Get-Service NTDS -ErrorAction SilentlyContinue | Where-Object Status -eq Running) { Write-Output ${q}Already a domain controller -- skipping forest promotion${q} } else { $pw = ConvertTo-SecureString ${q}${dsrmPassword}${q} -AsPlainText -Force; Install-ADDSForest -DomainName ${q}${domainName}${q} -DomainNetbiosName ${q}${netbiosName}${q} -SafeModeAdministratorPassword $pw -InstallDns:$true -CreateDnsDelegation:$false -DatabasePath ${q}C:\\Windows\\NTDS${q} -LogPath ${q}C:\\Windows\\NTDS${q} -SysvolPath ${q}C:\\Windows\\SYSVOL${q} -NoRebootOnCompletion:$false -Force:$true }; Stop-Transcript"'
    }
  }
}

output extensionId string = cse.id

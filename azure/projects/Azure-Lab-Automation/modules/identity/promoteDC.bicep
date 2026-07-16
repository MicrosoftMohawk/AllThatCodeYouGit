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

@description('Static IP of this domain controller. After forest promotion the NIC DNS client is reset to this IP as primary so the DC uses itself for DNS resolution — required for reliable AD replication, SYSVOL, and GPO delivery.')
param selfIp string

@description('IP of a secondary DNS server (e.g., DC02). Used as fallback when the primary (self) is unreachable. Leave empty to configure only the self IP.')
param secondaryDcIp string = ''

// Workaround: Bicep parser has issues with ''${...}'' (escaped quote + interpolation).
// Use a variable containing a single-quote character and interpolate it instead.
var q = '\''

// Secondary DNS part: ', '10.0.1.5'' when provided; empty string otherwise.
var secondaryDnsPart = empty(secondaryDcIp) ? '' : ', ${q}${secondaryDcIp}${q}'

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

// ---------------------------------------------------------------------------
// Post-Promotion DNS Reset
// After forest promotion the VM reboots automatically. Once it comes back up,
// this RunCommand resets the NIC DNS client to self-first (selfIp, then
// secondaryDcIp) so AD DNS registration and replication work correctly.
// Azure DHCP on reboot would already deliver the NIC-level dnsServers set on
// the ARM NIC, but this RunCommand ensures the OS-level setting is applied
// immediately and triggers ipconfig /registerdns + Netlogon restart.
// ---------------------------------------------------------------------------
resource resetDns 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  name: '${vmName}/ResetDnsPostPromotion'
  location: location
  tags: tags
  dependsOn: [cse]
  properties: {
    asyncExecution: false
    timeoutInSeconds: 120
    source: {
      script: 'Start-Transcript -Path C:\\WindowsTemp\\ResetDns.log -Append; $nic = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1; Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses ${q}${selfIp}${q}${secondaryDnsPart}; Start-Sleep -Seconds 10; ipconfig /registerdns; Restart-Service Netlogon -Force -ErrorAction SilentlyContinue; Stop-Transcript'
    }
  }
}

output extensionId string = cse.id

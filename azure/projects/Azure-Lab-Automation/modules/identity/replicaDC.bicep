// ============================================================================
// Module: Promote Replica Domain Controller (DC02)
// Uses CustomScriptExtension to set DNS to DC01, install AD DS, and promote
// as an additional domain controller in the existing domain.
// The VM reboots automatically after promotion.
// Idempotent: skips promotion if the NTDS service is already running.
// ============================================================================

@description('Name of the existing VM to promote as replica DC')
param vmName string

@description('Azure region')
param location string

@description('Fully qualified domain name (e.g., azlab.local)')
param domainName string

@description('IP address of the primary domain controller (DC01)')
param primaryDcIp string

@description('Domain admin username (without domain prefix)')
param adminUsername string

@secure()
@description('Domain admin password (same as VM admin password)')
param adminPassword string

@secure()
@description('Directory Services Restore Mode (DSRM) password')
param dsrmPassword string

@description('Tags')
param tags object = {}

@description('Static IP of this domain controller. After promotion the NIC DNS client is reset to this IP as primary so the DC uses itself for DNS resolution — required for reliable AD replication, SYSVOL, and GPO delivery.')
param selfIp string

var netbiosName = toUpper(split(domainName, '.')[0])

// Workaround: Bicep parser has issues with ''${...}'' (escaped quote + interpolation).
var q = '\''

// Post-promotion DNS reset script: points this DC's DNS client to itself first,
// then the primary DC as fallback. Runs after the promotion reboot.
var resetDnsScript = 'Start-Transcript -Path C:\\WindowsTemp\\ResetDns.log -Append; $nic = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1; Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses ${q}${selfIp}${q}, ${q}${primaryDcIp}${q}; Start-Sleep -Seconds 10; ipconfig /registerdns; Restart-Service Netlogon -Force -ErrorAction SilentlyContinue; Stop-Transcript'

// ---------------------------------------------------------------------------
// CustomScriptExtension — set DNS, wait for domain, install AD DS, promote
// All secrets embedded in protectedSettings (not visible in deployment logs).
// ---------------------------------------------------------------------------
resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: '${vmName}/PromoteReplicaDC'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Bypass -Command "Start-Transcript -Path C:\\WindowsTemp\\ReplicaDC.log -Append; $nic = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1; Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses ${q}${primaryDcIp}${q}; Write-Output ${q}DNS set to ${primaryDcIp}${q}; $maxWait = 900; $waited = 0; while ($waited -lt $maxWait) { try { Resolve-DnsName ${q}${domainName}${q} -DnsOnly -ErrorAction Stop | Out-Null; Write-Output ${q}Domain DNS resolved${q}; break } catch { Start-Sleep 15; $waited += 15 } }; if ($waited -ge $maxWait) { throw ${q}Domain not reachable within 900s${q} }; Install-WindowsFeature AD-Domain-Services -IncludeManagementTools; if (Get-Service NTDS -ErrorAction SilentlyContinue | Where-Object Status -eq Running) { Write-Output ${q}Already a domain controller -- skipping replica promotion${q} } else { $pw = ConvertTo-SecureString ${q}${adminPassword}${q} -AsPlainText -Force; $dsrm = ConvertTo-SecureString ${q}${dsrmPassword}${q} -AsPlainText -Force; $cred = New-Object System.Management.Automation.PSCredential(${q}${netbiosName}\\${adminUsername}${q}, $pw); $maxRetries = 10; $attempt = 0; $promoted = $false; while (-not $promoted -and $attempt -lt $maxRetries) { $attempt++; Write-Output ${q}DC promotion attempt $attempt of $maxRetries${q}; try { Install-ADDSDomainController -DomainName ${q}${domainName}${q} -Credential $cred -SafeModeAdministratorPassword $dsrm -InstallDns:$true -NoRebootOnCompletion:$false -Force:$true; $promoted = $true } catch { Write-Output ${q}Attempt $attempt failed: $_${q}; if ($attempt -lt $maxRetries) { Write-Output ${q}Waiting 60s before retry...${q}; Start-Sleep 60 } else { throw ${q}DC promotion failed after $maxRetries attempts: $_${q} } } } }; Stop-Transcript"'
    }
  }
}

// ---------------------------------------------------------------------------
// Post-Promotion DNS Reset
// After replica promotion the VM reboots. Once it comes back up, this
// RunCommand resets DNS client to [selfIp, primaryDcIp] so this DC uses
// itself as primary DNS — required for AD replication and GPO delivery.
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
      script: resetDnsScript
    }
  }
}

output extensionId string = cse.id

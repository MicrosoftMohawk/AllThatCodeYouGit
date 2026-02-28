// ============================================================================
// Module: Promote Replica Domain Controller (DC02)
// Uses CustomScriptExtension to set DNS to DC01, install AD DS, and promote
// as an additional domain controller in the existing domain.
// The VM reboots automatically after promotion.
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

var netbiosName = toUpper(split(domainName, '.')[0])

// Workaround: Bicep parser has issues with ''${...}'' (escaped quote + interpolation).
var q = '\''

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
      commandToExecute: 'powershell -ExecutionPolicy Bypass -Command "Start-Transcript -Path C:\\WindowsTemp\\ReplicaDC.log -Append; $nic = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1; Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses ${q}${primaryDcIp}${q}; Write-Output ${q}DNS set to ${primaryDcIp}${q}; $maxWait = 900; $waited = 0; while ($waited -lt $maxWait) { try { Resolve-DnsName ${q}${domainName}${q} -DnsOnly -ErrorAction Stop | Out-Null; Write-Output ${q}Domain DNS resolved${q}; break } catch { Start-Sleep 15; $waited += 15 } }; if ($waited -ge $maxWait) { throw ${q}Domain not reachable within 900s${q} }; Install-WindowsFeature AD-Domain-Services -IncludeManagementTools; $pw = ConvertTo-SecureString ${q}${adminPassword}${q} -AsPlainText -Force; $dsrm = ConvertTo-SecureString ${q}${dsrmPassword}${q} -AsPlainText -Force; $cred = New-Object System.Management.Automation.PSCredential(${q}${netbiosName}\\${adminUsername}${q}, $pw); $maxRetries = 10; $attempt = 0; $promoted = $false; while (-not $promoted -and $attempt -lt $maxRetries) { $attempt++; Write-Output ${q}DC promotion attempt $attempt of $maxRetries${q}; try { Install-ADDSDomainController -DomainName ${q}${domainName}${q} -Credential $cred -SafeModeAdministratorPassword $dsrm -InstallDns:$true -NoRebootOnCompletion:$false -Force:$true; $promoted = $true } catch { Write-Output ${q}Attempt $attempt failed: $_${q}; if ($attempt -lt $maxRetries) { Write-Output ${q}Waiting 60s before retry...${q}; Start-Sleep 60 } else { throw ${q}DC promotion failed after $maxRetries attempts: $_${q} } } }; Stop-Transcript"'
    }
  }
}

output extensionId string = cse.id

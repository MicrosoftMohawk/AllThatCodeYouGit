<#
.SYNOPSIS
    Configures DNS NRPT rules for Azure P2S VPN connections so private endpoints resolve correctly.

.DESCRIPTION
    When connected to an Azure VPN, private endpoints (Key Vault, Storage, etc.) must resolve
    to their private IPs via the Azure-hosted Private DNS Zones. By default, Windows uses the
    local network adapter's DNS (lower metric), which resolves to public IPs — breaking access
    when public network access is disabled.

    This script manages NRPT (Name Resolution Policy Table) rules that route Azure Private DNS
    zone queries through the lab's Domain Controllers. It supports three modes:

    - Install:   Creates NRPT rules AND a scheduled task that auto-adds/removes rules on
                 VPN connect/disconnect. (Requires elevation)
    - Uninstall: Removes the NRPT rules and scheduled task. (Requires elevation)
    - Apply:     Manually adds/removes NRPT rules based on current VPN connection state.
                 (Called automatically by the scheduled task, or run manually)

.PARAMETER Action
    Install  — Set up NRPT rules + scheduled task (requires Admin).
    Uninstall — Remove NRPT rules + scheduled task (requires Admin).
    Apply    — Add or remove NRPT rules based on current VPN state.

.PARAMETER BaseName
    The base name used during deployment (e.g., "tst10"). Used to identify the VPN connection.

.PARAMETER DnsServers
    IP addresses of the Azure DNS servers (Domain Controllers). Defaults to 10.0.1.4, 10.0.1.5.

.EXAMPLE
    .\Set-VpnDnsConfig.ps1 -Action Install -BaseName tst10
    # Sets up NRPT rules and a scheduled task (run as Admin)

.EXAMPLE
    .\Set-VpnDnsConfig.ps1 -Action Uninstall -BaseName tst10
    # Removes everything (run as Admin)

.EXAMPLE
    .\Set-VpnDnsConfig.ps1 -Action Apply -BaseName tst10
    # Manually toggle NRPT rules based on VPN connection state
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Uninstall', 'Apply')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [string[]]$DnsServers = @('10.0.1.4', '10.0.1.5')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Constants ───────────────────────────────────────────────────────────────

$VpnName  = "${BaseName}-vnet"
$TaskName = "AzureLabVpnDns-${BaseName}"

# Azure Private DNS zone suffixes that need to resolve via the lab DCs.
# Add more zones here as you add private endpoints for other services.
$PrivateDnsZones = @(
    '.vault.azure.net'                       # Key Vault
    '.privatelink.vaultcore.azure.net'       # Key Vault (privatelink CNAME)
    '.blob.core.windows.net'                 # Blob Storage
    '.privatelink.blob.core.windows.net'     # Blob Storage (privatelink)
    '.file.core.windows.net'                 # File Storage
    '.privatelink.file.core.windows.net'     # File Storage (privatelink)
)

# Tag used to identify NRPT rules created by this script (stored in Comment field)
$NrptTag = "AzureLabVpnDns-${BaseName}"

# ─── Helper functions ────────────────────────────────────────────────────────

function Write-Step  { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$msg) Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "   [WARN] $msg" -ForegroundColor Yellow }

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-VpnConnected {
    # Azure P2S VPN connections create PPP/RAS interfaces that don't appear in
    # Get-NetAdapter. Use Get-NetIPInterface which sees all interface types.
    $iface = Get-NetIPInterface -InterfaceAlias $VpnName -AddressFamily IPv4 -ErrorAction SilentlyContinue
    return ($null -ne $iface -and $iface.ConnectionState -eq 'Connected')
}

function Add-NrptRules {
    # Remove any existing rules from this script first to avoid duplicates
    Remove-NrptRules

    foreach ($zone in $PrivateDnsZones) {
        Add-DnsClientNrptRule -Namespace $zone -NameServers $DnsServers -Comment $NrptTag | Out-Null
    }
    Write-Ok "NRPT rules added for $($PrivateDnsZones.Count) private DNS zones -> $($DnsServers -join ', ')"
}

function Remove-NrptRules {
    $existing = Get-DnsClientNrptRule | Where-Object { $_.Comment -eq $NrptTag }
    foreach ($rule in $existing) {
        Remove-DnsClientNrptRule -Name $rule.Name -Force
    }
    if ($existing) {
        Write-Ok "Removed $($existing.Count) existing NRPT rules"
    }
}

# ─── Action: Apply ───────────────────────────────────────────────────────────

function Invoke-Apply {
    if (Test-VpnConnected) {
        Write-Step "VPN '$VpnName' is connected — adding NRPT rules..."
        Add-NrptRules
    }
    else {
        Write-Step "VPN '$VpnName' is not connected — removing NRPT rules..."
        Remove-NrptRules
    }
}

# ─── Action: Install ─────────────────────────────────────────────────────────

function Invoke-Install {
    if (-not (Test-IsAdmin)) {
        Write-Error "Install requires an elevated (Administrator) PowerShell session."
        return
    }

    Write-Step "Installing VPN DNS configuration for '$VpnName'..."

    # 1. Apply rules now if VPN is connected
    Invoke-Apply

    # 2. Create a scheduled task triggered by network state changes (Event ID 10000 = RasClient connect, 10001 = disconnect)
    $scriptPath = $MyInvocation.ScriptName
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }

    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command powershell).Source }

    $taskAction = New-ScheduledTaskAction `
        -Execute $pwshPath `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Apply -BaseName $BaseName -DnsServers $($DnsServers -join ',')"

    # Use CIM to create event-based triggers for RasClient connect/disconnect
    $cimTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler

    $connectTrigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly -Property @{
        Subscription = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">*[System[Provider[@Name='RasClient'] and EventID=20225]]</Select>
  </Query>
</QueryList>
"@
        Enabled = $true
    }

    $disconnectTrigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly -Property @{
        Subscription = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">*[System[Provider[@Name='RasClient'] and EventID=20226]]</Select>
  </Query>
</QueryList>
"@
        Enabled = $true
    }

    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -RunLevel Highest `
        -LogonType ServiceAccount

    # Remove existing task if present
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $taskAction `
        -Trigger $connectTrigger, $disconnectTrigger `
        -Settings $taskSettings `
        -Principal $taskPrincipal `
        -Description "Manages DNS NRPT rules for Azure lab VPN '$VpnName'. Auto-created by Set-VpnDnsConfig.ps1." `
        -Force | Out-Null

    Write-Ok "Scheduled task '$TaskName' created"
    Write-Ok "NRPT rules will be automatically added/removed on VPN connect/disconnect"
    Write-Host "`n   To uninstall: .\Set-VpnDnsConfig.ps1 -Action Uninstall -BaseName $BaseName" -ForegroundColor Gray
}

# ─── Action: Uninstall ───────────────────────────────────────────────────────

function Invoke-Uninstall {
    if (-not (Test-IsAdmin)) {
        Write-Error "Uninstall requires an elevated (Administrator) PowerShell session."
        return
    }

    Write-Step "Uninstalling VPN DNS configuration for '$VpnName'..."

    # Remove NRPT rules
    Remove-NrptRules

    # Remove scheduled task
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "Scheduled task '$TaskName' removed"
    }
    else {
        Write-Warn "Scheduled task '$TaskName' not found (already removed?)"
    }

    Write-Ok "VPN DNS configuration uninstalled"
}

# ─── Main ────────────────────────────────────────────────────────────────────

switch ($Action) {
    'Install'   { Invoke-Install }
    'Uninstall' { Invoke-Uninstall }
    'Apply'     { Invoke-Apply }
}

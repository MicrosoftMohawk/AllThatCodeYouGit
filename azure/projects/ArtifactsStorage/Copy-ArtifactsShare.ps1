<#
.SYNOPSIS
    Copy the contents of one artifacts file share to another (server-side AzCopy).

.DESCRIPTION
    Migrates the 'artifacts' Azure Files share between two ArtifactsStorage
    deployments (e.g., when you've stood up a new artifacts deployment in a
    different region and need to move data from the old one).

    Both accounts are deployed locked-down:
      - publicNetworkAccess = Disabled
      - allowSharedKeyAccess = false

    AzCopy cannot reach them over the private endpoint from an arbitrary
    workstation, and it cannot mint a SAS without shared-key access.  This
    script therefore:

      1. Discovers the source and target storage accounts (one each in
         '<prefix>-rg-artifacts').
      2. Captures their current network + auth settings.
      3. Temporarily enables public network access AND shared-key access
         on BOTH accounts.
      4. Mints short-lived (1 hour) account SAS tokens
         (read+list on source, read+write+create+list+delete on target).
      5. Runs 'azcopy copy' share -> share with --recursive
         (server-side, preserving SMB info + permissions where supported).
      6. In a finally block, restores the original network + auth settings
         on both accounts — even on failure or Ctrl-C.

    The temporary exposure window is typically a few minutes.  All actions are
    audit-logged in the Activity Log on each storage account.

.PARAMETER SourceNamePrefix
    NamePrefix of the SOURCE ArtifactsStorage deployment (the existing one).
    Used to find '<SourceNamePrefix>-rg-artifacts'.

.PARAMETER TargetNamePrefix
    NamePrefix of the TARGET ArtifactsStorage deployment (the new one).
    Used to find '<TargetNamePrefix>-rg-artifacts'.

.PARAMETER ShareName
    Azure Files share name on both accounts.  Default: 'artifacts'
    (matches the Bicep template).

.PARAMETER SasHours
    Lifetime of the temporary SAS tokens in hours.  Default: 2.

.PARAMETER SubscriptionId
    Target subscription ID.  Defaults to the current az CLI subscription.

.PARAMETER AzCopyPath
    Full path to azcopy.exe.  If omitted, the script searches PATH and a few
    common locations.  If not found, the script prints install instructions
    and exits.

.PARAMETER KeepUnlocked
    Skip the final lockdown step (leave both accounts with public + shared-key
    access enabled).  USE WITH CAUTION — intended only for debugging.

.PARAMETER WhatIf
    Show what would happen without making any changes.

.EXAMPLE
    # Copy from the old (cross-region) artifacts to the new gisa-region one
    .\Copy-ArtifactsShare.ps1 -SourceNamePrefix artifacts -TargetNamePrefix gisaart

.EXAMPLE
    # Dry-run
    .\Copy-ArtifactsShare.ps1 -SourceNamePrefix artifacts -TargetNamePrefix gisaart -WhatIf

.NOTES
    Requires: az CLI, azcopy.exe (https://aka.ms/downloadazcopy).
    The signed-in user must have at least 'Contributor' on both artifacts RGs
    in order to toggle network rules + list storage account keys.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$SourceNamePrefix,

    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$TargetNamePrefix,

    [Parameter(Mandatory = $false)]
    [string]$ShareName = 'artifacts',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 24)]
    [int]$SasHours = 2,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$AzCopyPath,

    [Parameter(Mandatory = $false)]
    [switch]$KeepUnlocked
)

# ============================================================================
# Helpers
# ============================================================================

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "[*] $Text" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Text)
    Write-Host "    OK  $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "    --  $Text" -ForegroundColor Gray
}

function Invoke-AzJson {
    param([Parameter(Mandatory = $true)][string]$Cmd)
    $raw = Invoke-Expression $Cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az command failed: $Cmd`n$raw"
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Find-AzCopy {
    param([string]$Override)
    if ($Override) {
        if (Test-Path $Override) { return $Override }
        throw "AzCopy not found at -AzCopyPath: $Override"
    }
    $cmd = Get-Command azcopy.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$env:ProgramFiles\AzCopy\azcopy.exe"
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Microsoft.Azure.AZCopy.10_Microsoft.Winget.Source_8wekyb3d8bbwe\azcopy.exe"
        "$env:USERPROFILE\azcopy\azcopy.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-StorageAccountState {
    param([string]$ResourceGroup, [string]$Name)
    $obj = Invoke-AzJson "az storage account show -g $ResourceGroup -n $Name -o json"
    return [pscustomobject]@{
        Name                  = $Name
        ResourceGroup         = $ResourceGroup
        Location              = $obj.location
        PublicNetworkAccess   = $obj.publicNetworkAccess
        AllowSharedKeyAccess  = $obj.allowSharedKeyAccess
        DefaultAction         = $obj.networkRuleSet.defaultAction
    }
}

function Set-StorageAccountAccess {
    param(
        [string]$ResourceGroup,
        [string]$Name,
        [ValidateSet('Enabled','Disabled')][string]$PublicNetworkAccess,
        [ValidateSet('true','false')][string]$AllowSharedKeyAccess,
        [ValidateSet('Allow','Deny')][string]$DefaultAction
    )
    $azArgs = @(
        "storage", "account", "update",
        "-g", $ResourceGroup, "-n", $Name,
        "--public-network-access", $PublicNetworkAccess,
        "--allow-shared-key-access", $AllowSharedKeyAccess,
        "--default-action", $DefaultAction,
        "-o", "none"
    )
    & az @azArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update storage account $Name (public=$PublicNetworkAccess, sharedKey=$AllowSharedKeyAccess, defaultAction=$DefaultAction)."
    }
}

function Restore-StorageAccount {
    param(
        [pscustomobject]$OriginalState
    )
    if (-not $OriginalState) { return }
    Write-Info "Restoring $($OriginalState.Name): public=$($OriginalState.PublicNetworkAccess), sharedKey=$($OriginalState.AllowSharedKeyAccess), defaultAction=$($OriginalState.DefaultAction)"
    try {
        Set-StorageAccountAccess `
            -ResourceGroup $OriginalState.ResourceGroup `
            -Name $OriginalState.Name `
            -PublicNetworkAccess $OriginalState.PublicNetworkAccess `
            -AllowSharedKeyAccess ([string]$OriginalState.AllowSharedKeyAccess).ToLower() `
            -DefaultAction $OriginalState.DefaultAction
        Write-OK "Restored $($OriginalState.Name)"
    } catch {
        Write-Host "    !!  Failed to restore $($OriginalState.Name): $_" -ForegroundColor Red
        Write-Host "        Manually verify: az storage account show -g $($OriginalState.ResourceGroup) -n $($OriginalState.Name) --query '{public:publicNetworkAccess,sharedKey:allowSharedKeyAccess,defaultAction:networkRuleSet.defaultAction}'" -ForegroundColor Red
    }
}

function New-AccountSas {
    param(
        [string]$AccountName,
        [string]$Permissions,
        [int]$Hours
    )
    $expiry = (Get-Date).ToUniversalTime().AddHours($Hours).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $sas = az storage account generate-sas `
        --account-name $AccountName `
        --services f `
        --resource-types sco `
        --permissions $Permissions `
        --expiry $expiry `
        --https-only `
        --auth-mode key `
        -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate SAS for $AccountName : $sas"
    }
    return [string]$sas
}

# ============================================================================
# Prereqs
# ============================================================================

Write-Header "Copy Artifacts Share"

Write-Step "Checking prerequisites"

# az
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) { throw "Azure CLI (az) is not installed or not on PATH." }
Write-OK "az CLI found: $($azCmd.Source)"

# az login
try {
    $account = Invoke-AzJson "az account show -o json"
    Write-OK "Signed in as: $($account.user.name) (tenant $($account.tenantId))"
} catch {
    throw "Not signed in to Azure CLI. Run 'az login' first."
}

# subscription
if ($SubscriptionId) {
    Write-Info "Setting subscription: $SubscriptionId"
    az account set --subscription $SubscriptionId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription $SubscriptionId" }
} else {
    $SubscriptionId = $account.id
    Write-Info "Using current subscription: $SubscriptionId ($($account.name))"
}

# azcopy
$azcopy = Find-AzCopy -Override $AzCopyPath
if (-not $azcopy) {
    Write-Host ""
    Write-Host "AzCopy was not found." -ForegroundColor Red
    Write-Host "  Install via winget:  winget install Microsoft.Azure.AZCopy.10" -ForegroundColor Yellow
    Write-Host "  Or download:         https://aka.ms/downloadazcopy" -ForegroundColor Yellow
    Write-Host "  Or pass -AzCopyPath <full path to azcopy.exe>" -ForegroundColor Yellow
    throw "AzCopy required."
}
Write-OK "AzCopy found: $azcopy"

# ============================================================================
# Discover source + target
# ============================================================================

Write-Step "Discovering source: '$SourceNamePrefix-rg-artifacts'"
$srcRg = "$SourceNamePrefix-rg-artifacts"
$srcAccounts = Invoke-AzJson "az storage account list -g $srcRg -o json"
if (-not $srcAccounts -or $srcAccounts.Count -eq 0) {
    throw "No storage account found in $srcRg. Did the source deployment succeed?"
}
if ($srcAccounts.Count -gt 1) {
    throw "Expected exactly 1 storage account in $srcRg, found $($srcAccounts.Count): $($srcAccounts.name -join ', ')"
}
$srcState = Get-StorageAccountState -ResourceGroup $srcRg -Name $srcAccounts[0].name
Write-OK "Source: $($srcState.Name) ($($srcState.Location))"
Write-Info "  publicNetworkAccess=$($srcState.PublicNetworkAccess), allowSharedKeyAccess=$($srcState.AllowSharedKeyAccess), defaultAction=$($srcState.DefaultAction)"

Write-Step "Discovering target: '$TargetNamePrefix-rg-artifacts'"
$tgtRg = "$TargetNamePrefix-rg-artifacts"
$tgtAccounts = Invoke-AzJson "az storage account list -g $tgtRg -o json"
if (-not $tgtAccounts -or $tgtAccounts.Count -eq 0) {
    throw "No storage account found in $tgtRg. Deploy the target first with .\deploy.ps1 -NamePrefix $TargetNamePrefix ..."
}
if ($tgtAccounts.Count -gt 1) {
    throw "Expected exactly 1 storage account in $tgtRg, found $($tgtAccounts.Count): $($tgtAccounts.name -join ', ')"
}
$tgtState = Get-StorageAccountState -ResourceGroup $tgtRg -Name $tgtAccounts[0].name
Write-OK "Target: $($tgtState.Name) ($($tgtState.Location))"
Write-Info "  publicNetworkAccess=$($tgtState.PublicNetworkAccess), allowSharedKeyAccess=$($tgtState.AllowSharedKeyAccess), defaultAction=$($tgtState.DefaultAction)"

if ($srcState.Name -eq $tgtState.Name) {
    throw "Source and target are the same storage account ($($srcState.Name)). Aborting."
}

# ============================================================================
# Plan summary
# ============================================================================

Write-Header "Plan"
Write-Host "  Source : $($srcState.Name) in $($srcState.Location) (rg: $srcRg)" -ForegroundColor White
Write-Host "  Target : $($tgtState.Name) in $($tgtState.Location) (rg: $tgtRg)" -ForegroundColor White
Write-Host "  Share  : $ShareName  (server-side AzCopy, --recursive, --preserve-smb-info)" -ForegroundColor White
Write-Host "  SAS TTL: $SasHours hour(s)" -ForegroundColor White
Write-Host ""
Write-Host "  Steps:" -ForegroundColor White
Write-Host "    1. Temporarily enable public+sharedKey on BOTH accounts" -ForegroundColor White
Write-Host "    2. Mint short-lived account SAS for each" -ForegroundColor White
Write-Host "    3. azcopy copy <src>/$ShareName <tgt>/$ShareName --recursive --preserve-smb-info" -ForegroundColor White
if ($KeepUnlocked) {
    Write-Host "    4. !! SKIPPING lockdown (-KeepUnlocked specified)" -ForegroundColor Red
} else {
    Write-Host "    4. Restore original network+auth settings on BOTH accounts (always, even on error)" -ForegroundColor White
}

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "[WhatIf] No changes made." -ForegroundColor Magenta
    return
}

if (-not $PSCmdlet.ShouldProcess("$($srcState.Name) -> $($tgtState.Name)", "Copy file share '$ShareName'")) {
    return
}

# ============================================================================
# Execute
# ============================================================================

# Capture original state for restoration (BEFORE any changes)
$origSrc = $srcState.PSObject.Copy()
$origTgt = $tgtState.PSObject.Copy()
$srcUnlocked = $false
$tgtUnlocked = $false

try {
    Write-Step "Unlocking source: $($srcState.Name)"
    Set-StorageAccountAccess `
        -ResourceGroup $srcRg -Name $srcState.Name `
        -PublicNetworkAccess 'Enabled' `
        -AllowSharedKeyAccess 'true' `
        -DefaultAction 'Allow'
    $srcUnlocked = $true
    Write-OK "Source unlocked (public + sharedKey)"

    Write-Step "Unlocking target: $($tgtState.Name)"
    Set-StorageAccountAccess `
        -ResourceGroup $tgtRg -Name $tgtState.Name `
        -PublicNetworkAccess 'Enabled' `
        -AllowSharedKeyAccess 'true' `
        -DefaultAction 'Allow'
    $tgtUnlocked = $true
    Write-OK "Target unlocked (public + sharedKey)"

    Write-Step "Waiting for network rule propagation (15s)"
    Start-Sleep -Seconds 15

    Write-Step "Minting account SAS tokens (TTL: $SasHours h)"
    # Source: read + list
    $srcSas = New-AccountSas -AccountName $srcState.Name -Permissions 'rl' -Hours $SasHours
    Write-OK "Source SAS generated ($(($srcSas).Length) chars)"
    # Target: read + write + create + list + delete (delete needed for overwrite semantics)
    $tgtSas = New-AccountSas -AccountName $tgtState.Name -Permissions 'rwcdl' -Hours $SasHours
    Write-OK "Target SAS generated ($(($tgtSas).Length) chars)"

    $srcUrl = "https://$($srcState.Name).file.core.windows.net/$ShareName"
    $tgtUrl = "https://$($tgtState.Name).file.core.windows.net/$ShareName"
    $srcUrlSas = "$srcUrl`?$srcSas"
    $tgtUrlSas = "$tgtUrl`?$tgtSas"

    Write-Step "Running AzCopy"
    Write-Info "azcopy copy `"$srcUrl?<SAS>`" `"$tgtUrl?<SAS>`" --recursive --preserve-smb-info"
    Write-Host ""

    # --preserve-smb-info: preserves last-write/creation timestamps & attrs
    # --preserve-smb-permissions: requires both accounts to have AD/Entra
    #   integration; we skip it here because the target may not be AD-registered yet.
    #   Permissions will be re-applied on the new share when the lab mounts and
    #   writes new files; for migrated files, ACLs default to share root inheritance.
    & $azcopy copy $srcUrlSas $tgtUrlSas `
        --recursive `
        --preserve-smb-info=true `
        --overwrite=ifSourceNewer
    $azcopyExit = $LASTEXITCODE

    Write-Host ""
    if ($azcopyExit -ne 0) {
        throw "azcopy exited with code $azcopyExit. See output above."
    }
    Write-OK "AzCopy completed successfully"

} finally {
    Write-Step "Restoring original storage account state"
    if ($KeepUnlocked) {
        Write-Host "    !!  -KeepUnlocked specified — leaving accounts unlocked." -ForegroundColor Red
        Write-Host "        Source: $($srcState.Name)  (public=Enabled, sharedKey=true)" -ForegroundColor Red
        Write-Host "        Target: $($tgtState.Name)  (public=Enabled, sharedKey=true)" -ForegroundColor Red
        Write-Host "        Re-lock manually when done." -ForegroundColor Red
    } else {
        if ($srcUnlocked) { Restore-StorageAccount -OriginalState $origSrc }
        if ($tgtUnlocked) { Restore-StorageAccount -OriginalState $origTgt }
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Header "Copy Complete"
Write-Host "  Source : $($srcState.Name) ($($srcState.Location))" -ForegroundColor White
Write-Host "  Target : $($tgtState.Name) ($($tgtState.Location))" -ForegroundColor White
Write-Host "  Share  : $ShareName" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Associate the new artifacts with your lab (if not already done):" -ForegroundColor Gray
Write-Host "       .\Associate-Lab.ps1 -NamePrefix $TargetNamePrefix -LabBaseName <lab>" -ForegroundColor Gray
Write-Host "  2. Verify content from a domain-joined VM:" -ForegroundColor Gray
Write-Host "       net use Z: \\$($tgtState.Name).file.core.windows.net\$ShareName" -ForegroundColor Gray
Write-Host "       dir Z:\" -ForegroundColor Gray
Write-Host "  3. Once you've confirmed everything works, delete the old artifacts RG:" -ForegroundColor Gray
Write-Host "       .\deploy.ps1 -NamePrefix $SourceNamePrefix -Destroy" -ForegroundColor Gray
Write-Host ""

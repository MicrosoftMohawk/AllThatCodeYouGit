<#
.SYNOPSIS
    Copy the contents of one artifacts file share to another (server-side AzCopy).

.DESCRIPTION
    Migrates the 'artifacts' Azure Files share between two ArtifactsStorage
    deployments (e.g., when you've stood up a new artifacts deployment in a
    different region and need to move data from the old one).

    Both accounts are deployed locked-down:
      - publicNetworkAccess = Disabled
      - allowSharedKeyAccess = false (enforced by Azure Policy
        'StorageAccount_DisableLocalAuth_Modify', so SAS/shared-key auth is
        impossible — the setting reverts to false on every write).

    AzCopy therefore authenticates with Microsoft Entra ID (OAuth) using the
    current 'az login' credential, and only the public network access is
    toggled.  This script:

      1. Discovers the source and target storage accounts (one each in
         '<prefix>-rg-artifacts').
      2. Captures their current network settings.
      3. Temporarily enables public network access (defaultAction=Allow)
         on BOTH accounts.
      4. Sets AZCOPY_AUTO_LOGIN_TYPE=AZCLI so AzCopy uses the signed-in
         identity's data-plane RBAC (no SAS, no shared key).
      5. Runs 'azcopy copy' share -> share with --from-to FileFile --recursive
         (preserving SMB info).
      6. In a finally block, restores the original network settings on both
         accounts — even on failure or Ctrl-C.

    The signed-in identity must hold a data-plane role on BOTH accounts, e.g.
    'Storage File Data Privileged Contributor' (or Reader on source / Contributor
    on target).

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
    Deprecated / unused.  Retained for backward compatibility; OAuth auth does
    not use SAS tokens.

.PARAMETER SubscriptionId
    Target subscription ID.  Defaults to the current az CLI subscription.

.PARAMETER AzCopyPath
    Full path to azcopy.exe.  If omitted, the script searches PATH and a few
    common locations.  If not found, the script prints install instructions
    and exits.

.PARAMETER KeepUnlocked
    Skip the final lockdown step (leave both accounts with public network
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
    Requires: az CLI (logged in), azcopy.exe (https://aka.ms/downloadazcopy).
    The signed-in identity must have:
      - 'Contributor' (control-plane) on both artifacts RGs to toggle network rules, and
      - a data-plane file role on BOTH accounts, e.g.
        'Storage File Data Privileged Contributor'.
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
        "$env:USERPROFILE\azcopy\azcopy.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    # winget installs azcopy into a versioned subfolder under the package dir,
    # e.g. ...\Microsoft.Azure.AZCopy.10_*\azcopy_windows_amd64_10.x.y\azcopy.exe
    $searchRoots = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
        "$env:ProgramFiles"
    )
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -Filter azcopy.exe -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 -ExpandProperty FullName
            if ($found) { return $found }
        }
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

function Wait-OAuthReady {
    # After enabling publicNetworkAccess, the network rule change can take a
    # minute or two to propagate.  Poll a lightweight OAuth (Entra ID) call
    # until it succeeds or we time out.  Uses --auth-mode login with backup
    # intent (the Privileged data-plane role authorizes the backup intent that
    # OAuth access to Azure Files requires).
    param(
        [string]$AccountName,
        [string]$ShareName,
        [int]$TimeoutSeconds = 300,
        [int]$IntervalSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        $out = az storage file list `
            --share-name $ShareName `
            --account-name $AccountName `
            --auth-mode login `
            --backup-intent `
            --num-results 1 `
            -o none 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "$AccountName reachable over OAuth (after $attempt attempt(s))"
            return
        }
        # Network not yet open -> connection/timeout/403 from firewall.
        # AuthorizationPermissionMismatch means RBAC isn't propagated/assigned.
        if ("$out" -match 'AuthorizationPermissionMismatch|does not have permission') {
            throw "OAuth readiness for $AccountName failed (RBAC): the signed-in identity lacks a data-plane role (e.g. 'Storage File Data Privileged Contributor') on this account.`n$out"
        }
        Write-Info "$AccountName not reachable yet; waiting ${IntervalSeconds}s..."
        Start-Sleep -Seconds $IntervalSeconds
    }
    throw "Timed out after ${TimeoutSeconds}s waiting for $AccountName to be reachable over OAuth."
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
Write-Host "  Share  : $ShareName  (server-side AzCopy, Entra ID auth, --recursive, --preserve-smb-info)" -ForegroundColor White
Write-Host ""
Write-Host "  Steps:" -ForegroundColor White
Write-Host "    1. Temporarily enable public network access on BOTH accounts" -ForegroundColor White
Write-Host "    2. Authenticate AzCopy via current 'az login' (Entra ID / OAuth)" -ForegroundColor White
Write-Host "    3. azcopy copy <src>/$ShareName <tgt>/$ShareName --from-to FileFile --recursive --preserve-smb-info" -ForegroundColor White
if ($KeepUnlocked) {
    Write-Host "    4. !! SKIPPING lockdown (-KeepUnlocked specified)" -ForegroundColor Red
} else {
    Write-Host "    4. Restore original network settings on BOTH accounts (always, even on error)" -ForegroundColor White
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
    Write-Step "Unlocking source network: $($srcState.Name)"
    Set-StorageAccountAccess `
        -ResourceGroup $srcRg -Name $srcState.Name `
        -PublicNetworkAccess 'Enabled' `
        -AllowSharedKeyAccess ([string]$srcState.AllowSharedKeyAccess).ToLower() `
        -DefaultAction 'Allow'
    $srcUnlocked = $true
    Write-OK "Source public network access enabled"

    Write-Step "Unlocking target network: $($tgtState.Name)"
    Set-StorageAccountAccess `
        -ResourceGroup $tgtRg -Name $tgtState.Name `
        -PublicNetworkAccess 'Enabled' `
        -AllowSharedKeyAccess ([string]$tgtState.AllowSharedKeyAccess).ToLower() `
        -DefaultAction 'Allow'
    $tgtUnlocked = $true
    Write-OK "Target public network access enabled"

    # Authenticate AzCopy via the current az CLI login (Entra ID / OAuth).
    # These accounts enforce allowSharedKeyAccess=false (Azure Policy
    # 'StorageAccount_DisableLocalAuth_Modify'), so SAS/shared-key auth is not
    # possible.  OAuth uses the signed-in identity's data-plane RBAC instead.
    # The signed-in user needs 'Storage File Data Privileged Contributor' (or
    # Reader on source / Contributor on target) on both accounts.
    Write-Step "Configuring AzCopy for Entra ID (OAuth) auth"
    $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI'
    Write-OK "AZCOPY_AUTO_LOGIN_TYPE=AZCLI (uses current 'az login' credential)"

    $srcUrl = "https://$($srcState.Name).file.core.windows.net/$ShareName"
    $tgtUrl = "https://$($tgtState.Name).file.core.windows.net/$ShareName"

    Write-Step "Waiting for public network access to propagate"
    Write-Info "This can take a minute or two after enabling public access."
    Wait-OAuthReady -AccountName $srcState.Name -ShareName $ShareName
    Wait-OAuthReady -AccountName $tgtState.Name -ShareName $ShareName

    Write-Step "Running AzCopy (Entra ID auth)"
    Write-Info "azcopy copy `"$srcUrl`" `"$tgtUrl`" --from-to FileFile --recursive --preserve-smb-info"
    Write-Host ""

    # --from-to FileFile: required so AzCopy treats both endpoints as Azure Files
    #   over OAuth (it adds the x-ms-file-request-intent: backup header that the
    #   Privileged data roles authorize).
    # --preserve-smb-info: preserves last-write/creation timestamps & attrs.
    # --preserve-smb-permissions: skipped — requires both accounts AD-registered;
    #   migrated files inherit the target share root ACLs.
    & $azcopy copy $srcUrl $tgtUrl `
        --from-to FileFile `
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
    $env:AZCOPY_AUTO_LOGIN_TYPE = $null
    Write-Step "Restoring original storage account state"
    if ($KeepUnlocked) {
        Write-Host "    !!  -KeepUnlocked specified — leaving accounts unlocked." -ForegroundColor Red
        Write-Host "        Source: $($srcState.Name)  (public=Enabled)" -ForegroundColor Red
        Write-Host "        Target: $($tgtState.Name)  (public=Enabled)" -ForegroundColor Red
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

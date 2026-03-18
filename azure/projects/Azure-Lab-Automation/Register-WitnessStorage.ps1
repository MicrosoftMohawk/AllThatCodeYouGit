<#
.SYNOPSIS
    Register the File Share Witness storage account in Active Directory.
    Enables Kerberos SMB authentication for WSFC quorum from domain-joined VMs.

.DESCRIPTION
    Standalone script that performs the same witness registration as deploy.ps1's
    Tier 2 post-deployment step.  Use this when the lab is already deployed and
    you need to register (or re-register) the witness storage account in AD
    without re-running the full deployment.

    Follows the same proven flow as the ArtifactsStorage deploy.ps1:
      1. Discovers the witness storage account by tag in {base}-rg-identity
      2. Auto-detects the AD domain name from DC01
      3. Temporarily enables shared key access
      4. Generates the kerb1 Kerberos key
      5. Runs Register-StorageInAD.ps1 on DC01 via RunCommand
      6. Configures the storage account with AD DS identity
      7. Flushes KDC cache on DC02
      8. Verifies Kerberos SMB mount from an AOAG SQL node
      9. On failure: regenerates kerb key, re-registers, retries
     10. Re-disables shared key access

.PARAMETER BaseName
    Base name prefix used during lab deployment (e.g., "azlab").

.PARAMETER DomainName
    AD domain FQDN.  If not specified, auto-detected from DC01.

.PARAMETER SubscriptionId
    Target Azure subscription ID.  If not set, uses current az CLI default.

.PARAMETER Force
    Re-register even if the storage account is already configured for AD DS.

.PARAMETER SkipVerify
    Skip the Kerberos SMB mount verification step.

.EXAMPLE
    .\Register-WitnessStorage.ps1 -BaseName azlab

.EXAMPLE
    .\Register-WitnessStorage.ps1 -BaseName azlab -DomainName azlab.local

.EXAMPLE
    .\Register-WitnessStorage.ps1 -BaseName azlab -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [string]$DomainName,

    [string]$SubscriptionId,

    [switch]$Force,

    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

# =============================================================================
# Helpers
# =============================================================================
function Write-Header { param([string]$Message) Write-Host "`n============================================================" -ForegroundColor Cyan; Write-Host "  $Message" -ForegroundColor Cyan; Write-Host "============================================================" -ForegroundColor Cyan }
function Write-Step   { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Yellow }
function Write-Ok     { param([string]$Message) Write-Host "   [OK] $Message" -ForegroundColor Green }
function Write-Fail   { param([string]$Message) Write-Host "   [FAIL] $Message" -ForegroundColor Red }

# =============================================================================
# 1. Prerequisites
# =============================================================================
Write-Header "Register File Share Witness -- Prerequisites"

# --- Azure CLI ----------------------------------------------------------------
Write-Step "Checking Azure CLI..."
try {
    $azVersionOutput = az version 2>&1 | ConvertFrom-Json
    $azCliVersion = $azVersionOutput.'azure-cli'
    if ([version]$azCliVersion -lt [version]'2.20.0') {
        Write-Fail "Azure CLI version $azCliVersion is too old. Minimum: 2.20.0"
        exit 1
    }
    Write-Ok "Azure CLI $azCliVersion"
} catch {
    Write-Fail "Azure CLI not found. Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# --- Login session ------------------------------------------------------------
Write-Step "Checking Azure login session..."
try {
    az account get-access-token 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "token expired" }
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Ok "Logged in as $($account.user.name) (tenant: $($account.tenantId))"
} catch {
    Write-Host "   Session expired or invalid. Opening browser login..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) { Write-Fail "Login failed."; exit 1 }
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Ok "Logged in as $($account.user.name)"
}

# --- Subscription selection ---------------------------------------------------
$rgIdentity = "$BaseName-rg-identity"

if ($SubscriptionId) {
    Write-Step "Setting subscription to $SubscriptionId..."
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to set subscription."; exit 1 }
    $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
    Write-Ok "$($currentSub.name) ($($currentSub.id))"
} else {
    $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
    Write-Step "Checking subscription '$($currentSub.name)' for resource group $rgIdentity..."
    $rgCheck = az group exists --name $rgIdentity -o tsv 2>&1
    if ($rgCheck -ne 'true') {
        Write-Host "   Resource group '$rgIdentity' not found in current subscription." -ForegroundColor Yellow
        Write-Step "Searching all accessible subscriptions for $rgIdentity..."
        $allSubs = az account list --query "[?state=='Enabled'].{name:name, id:id}" -o json 2>&1 | ConvertFrom-Json
        $matchingSubs = @()
        foreach ($sub in $allSubs) {
            if ($sub.id -eq $currentSub.id) { continue }
            az account set --subscription $sub.id 2>&1 | Out-Null
            $found = az group exists --name $rgIdentity -o tsv 2>&1
            if ($found -eq 'true') {
                $matchingSubs += $sub
            }
        }
        if ($matchingSubs.Count -eq 1) {
            $picked = $matchingSubs[0]
            az account set --subscription $picked.id
            $currentSub = $picked
            Write-Ok "Found in subscription: $($picked.name) ($($picked.id))"
        } elseif ($matchingSubs.Count -gt 1) {
            Write-Host ""
            Write-Host "   Found '$rgIdentity' in multiple subscriptions:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $matchingSubs.Count; $i++) {
                Write-Host "     [$($i + 1)] $($matchingSubs[$i].name)  ($($matchingSubs[$i].id))" -ForegroundColor White
            }
            $choice = Read-Host "   Select subscription (1-$($matchingSubs.Count))"
            $idx = [int]$choice - 1
            if ($idx -lt 0 -or $idx -ge $matchingSubs.Count) {
                Write-Fail "Invalid selection."
                exit 1
            }
            $picked = $matchingSubs[$idx]
            az account set --subscription $picked.id
            $currentSub = $picked
            Write-Ok "Using subscription: $($picked.name) ($($picked.id))"
        } else {
            az account set --subscription $currentSub.id 2>&1 | Out-Null
            Write-Fail "Resource group '$rgIdentity' not found in any accessible subscription."
            Write-Host "   Ensure the lab has been deployed with BaseName '$BaseName'." -ForegroundColor Yellow
            exit 1
        }
    } else {
        Write-Ok "Subscription: $($currentSub.name) ($($currentSub.id))"
    }
}

# =============================================================================
# 2. Discover witness storage account
# =============================================================================
$dcVmName   = "$BaseName-dc01"
$dc02VmName = "$BaseName-dc02"

Write-Header "Discovering Witness Storage Account"

Write-Step "Looking up storage account with tag workload=file-share-witness..."
$witnessStgName = az storage account list `
    --resource-group $rgIdentity `
    --query "[?tags.workload=='file-share-witness'].name | [0]" -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($witnessStgName)) {
    Write-Fail "Could not find witness storage account in $rgIdentity."
    Write-Host "   Ensure the lab Tier 1 has been deployed with a File Share Witness storage account." -ForegroundColor Yellow
    exit 1
}
$witnessStgName = $witnessStgName.Trim()
Write-Ok "Witness storage account: $witnessStgName"

# --- Check if already registered ---
$addsEnabled = az storage account show `
    --name $witnessStgName -g $rgIdentity `
    --query "azureFilesIdentityBasedAuthentication.directoryServiceOptions" -o tsv 2>&1
if (($addsEnabled -eq 'AADDS' -or $addsEnabled -eq 'AD') -and -not $Force) {
    Write-Ok "Storage account is already registered for AD DS authentication."
    Write-Host "   Use -Force to re-register (regenerate Kerberos key and update AD)." -ForegroundColor Yellow
    exit 0
}
if ($Force -and ($addsEnabled -eq 'AADDS' -or $addsEnabled -eq 'AD')) {
    Write-Host "   -Force specified -- re-registering despite existing AD DS config." -ForegroundColor Yellow
}

# =============================================================================
# 3. Auto-detect domain name from DC01
# =============================================================================
if ([string]::IsNullOrWhiteSpace($DomainName)) {
    Write-Step "Auto-detecting domain name from DC01..."
    $domainResult = az vm run-command invoke `
        --resource-group $rgIdentity `
        --name $dcVmName `
        --command-id RunPowerShellScript `
        --scripts "Get-ADDomain | Select-Object -ExpandProperty DnsRoot" `
        --query "value[0].message" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and $domainResult -match '\.') {
        $detected = ($domainResult -split "`n" | Where-Object { $_ -match '\.' -and $_ -notmatch 'Enable' -and $_ -notmatch '\[std' } | Select-Object -Last 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($detected)) {
            $DomainName = $detected
            Write-Ok "Domain: $DomainName"
        }
    }
    if ([string]::IsNullOrWhiteSpace($DomainName)) {
        Write-Fail "Could not auto-detect domain name from DC01."
        Write-Host "   Specify manually: -DomainName azlab.local" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Ok "Domain (from parameter): $DomainName"
}

# =============================================================================
# 4. Temporarily enable shared key access
# =============================================================================
Write-Header "Registering Witness Storage in AD"

Write-Step "Temporarily enabling shared key access..."
az storage account update `
    --name $witnessStgName -g $rgIdentity `
    --allow-shared-key-access true -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to enable shared key access."
    exit 1
}
Write-Ok "Shared key access enabled"

# =============================================================================
# 5. Generate and retrieve Kerberos key
# =============================================================================
Write-Step "Generating Kerberos key (kerb1)..."
az storage account keys renew `
    --account-name $witnessStgName -g $rgIdentity `
    --key key1 --key-type kerb -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to generate Kerberos key."
    exit 1
}

$kerbKey = az storage account keys list `
    --account-name $witnessStgName -g $rgIdentity `
    --query "[?keyName=='kerb1'].value" -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kerbKey)) {
    Write-Fail "Failed to retrieve Kerberos key."
    exit 1
}
$kerbKey = $kerbKey.Trim()
Write-Ok "Kerberos key generated (kerb1)"

# =============================================================================
# 6. Run Register-StorageInAD.ps1 on DC01 via RunCommand
# =============================================================================
Write-Step "Registering storage account in AD (running on DC01)..."

$adScriptPath = Join-Path $ScriptRoot 'modules' 'identity' 'scripts' 'Register-StorageInAD.ps1'
if (-not (Test-Path $adScriptPath)) {
    Write-Fail "Register-StorageInAD.ps1 not found at: $adScriptPath"
    exit 1
}

# Read the script, strip the <# #> comment block and param() block.
# az vm run-command invoke doesn't reliably bind to PowerShell param() blocks
# when using @file.  Instead, we prepend variable assignments directly.
$adScriptContent = Get-Content $adScriptPath -Raw
$adScriptContent = $adScriptContent -replace '(?s)<#.*?#>\s*', ''
$adScriptContent = $adScriptContent -replace '(?sm)param\s*\(.*?^\)\s*', ''

# Prepend variable assignments with the actual values
$domainDNParts = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','
$ouPath = "OU=Storage Accounts,OU=Lab Servers,$domainDNParts"
$preamble = @"
`$StorageAccountName = '$($witnessStgName -replace "'","''")'
`$StorageKerbKey = '$($kerbKey -replace "'","''")'
`$DomainName = '$($DomainName -replace "'","''")'
`$OUPath = '$($ouPath -replace "'","''")'

"@
$adScriptContent = $preamble + $adScriptContent

# Write to temp file and invoke via @file
$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "Register-WitnessInAD-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
$adScriptContent | Set-Content -Path $tempScript -Encoding UTF8 -NoNewline

$adResultRaw = az vm run-command invoke `
    --resource-group $rgIdentity `
    --name $dcVmName `
    --command-id RunPowerShellScript `
    --scripts "@$tempScript" `
    -o json 2>&1

Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

# Parse the full JSON response to get both stdout and stderr
$adResultText = ($adResultRaw | ForEach-Object { "$_" }) -join "`n"
try {
    $adResultJson = $adResultText | ConvertFrom-Json
    $stdout = $adResultJson.value | Where-Object { $_.code -match 'StdOut' } | Select-Object -ExpandProperty message
    $stderr = $adResultJson.value | Where-Object { $_.code -match 'StdErr' } | Select-Object -ExpandProperty message
} catch {
    $stdout = $adResultText
    $stderr = ''
}

if ($LASTEXITCODE -ne 0) {
    Write-Fail "AD registration failed on DC01."
    if ($stderr) { Write-Host "   stderr: $stderr" -ForegroundColor Gray }
    if ($stdout) { Write-Host "   stdout: $stdout" -ForegroundColor Gray }
    az storage account update --name $witnessStgName -g $rgIdentity --allow-shared-key-access false -o none 2>&1 | Out-Null
    exit 1
}

$jsonMatch = [regex]::Match($stdout, 'AD_REGISTRATION_RESULT=(.+)')
if (-not $jsonMatch.Success) {
    Write-Fail "Could not parse AD registration output."
    Write-Host "   --- DC01 stdout ---" -ForegroundColor Gray
    if ($stdout) { ($stdout -split "`n") | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray } }
    Write-Host "   --- DC01 stderr ---" -ForegroundColor Gray
    if ($stderr) { ($stderr -split "`n") | ForEach-Object { Write-Host "   $_" -ForegroundColor Red } }
    Write-Host "   --- end ---" -ForegroundColor Gray
    az storage account update --name $witnessStgName -g $rgIdentity --allow-shared-key-access false -o none 2>&1 | Out-Null
    exit 1
}

$capturedJson = $jsonMatch.Groups[1].Value
try {
    $adInfo = $capturedJson | ConvertFrom-Json
} catch {
    Write-Fail "Failed to parse AD registration JSON."
    Write-Host "   captured value: $capturedJson" -ForegroundColor Gray
    az storage account update --name $witnessStgName -g $rgIdentity --allow-shared-key-access false -o none 2>&1 | Out-Null
    exit 1
}
Write-Ok "Computer account: $($adInfo.computerName)"
Write-Ok "SPN: $($adInfo.spn)"
Write-Ok "Azure Storage SID: $($adInfo.azureStorageSid)"

# =============================================================================
# 7. Configure storage account with AD DS identity
# =============================================================================
Write-Step "Configuring storage account for AD DS authentication..."

az storage account update `
    --name $witnessStgName -g $rgIdentity `
    --enable-files-adds true `
    --domain-name $DomainName `
    --net-bios-domain-name $adInfo.netBiosDomainName `
    --forest-name $adInfo.forestName `
    --domain-guid $adInfo.domainGuid `
    --domain-sid $adInfo.domainSid `
    --azure-storage-sid $adInfo.azureStorageSid `
    --sam-account-name $adInfo.computerName `
    --account-type Computer `
    --default-share-permission StorageFileDataSmbShareContributor `
    -o none 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to configure AD DS authentication on storage account."
    az storage account update --name $witnessStgName -g $rgIdentity --allow-shared-key-access false -o none 2>&1 | Out-Null
    exit 1
}
Write-Ok "AD DS authentication enabled on witness storage account"

# =============================================================================
# 8. Flush KDC cache on DC02
# =============================================================================
# Register-StorageInAD.ps1 restarted DC01's KDC after ktpass and triggered
# repadmin /syncall.  DC02 received the new key via replication but its KDC
# may still cache the old AES key.  A KDC restart ensures it issues valid
# service tickets.
Write-Step "Flushing KDC cache on DC02..."
az vm run-command invoke `
    --resource-group $rgIdentity `
    --name $dc02VmName `
    --command-id RunPowerShellScript `
    --scripts "Restart-Service kdc -Force; Write-Host 'KDC restarted'" `
    --query "value[0].message" -o tsv 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "DC02 KDC cache flushed"
} else {
    Write-Host "   Warning: could not restart KDC on DC02. SMB mount may fail from some VMs until DC02 caches refresh." -ForegroundColor Yellow
}

# =============================================================================
# 9. Verify Kerberos SMB mount from a domain-joined VM
# =============================================================================
if (-not $SkipVerify) {
    $testRg = "$BaseName-rg-site2"
    $testVmCandidates = @("$BaseName-sqc1", "$BaseName-sqc2")
    $testVm = $null

    Write-Step "Finding a domain-joined VM for mount verification..."
    foreach ($candidate in $testVmCandidates) {
        $vmState = az vm get-instance-view -g $testRg -n $candidate `
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" `
            -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $vmState -match 'running') {
            $testVm = $candidate
            Write-Ok "Test VM: $testVm ($testRg)"
            break
        }
    }

    if (-not $testVm) {
        Write-Host "   No running AOAG SQL node found. Skipping mount verification." -ForegroundColor Yellow
        Write-Host "   Verify manually: net use Z: \\$witnessStgName.file.core.windows.net\witness" -ForegroundColor Yellow
    } else {
        $kerbVerifyScript = Join-Path ([System.IO.Path]::GetTempPath()) `
            "Verify-WitnessMount-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"

        # Build mount-test script.  $witnessStgName is expanded now;
        # everything else stays literal inside the remote script.
        $kerbVerifyContent = @"
klist purge 2>&1 | Out-Null
net use * /delete /y 2>&1 | Out-Null
Start-Sleep -Seconds 2
`$r = net use Z: "\\$witnessStgName.file.core.windows.net\witness" 2>&1
Write-Host "MOUNT_EXIT=`$LASTEXITCODE"
`$r | ForEach-Object { Write-Host `$_ }
net use Z: /delete 2>&1 | Out-Null
"@

        $kerbVerified = $false
        $maxRetries   = 1

        for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {

            # -- On retry: regenerate kerb key, re-register in AD, flush KDCs --
            if ($attempt -gt 0) {
                Write-Step "Retry $attempt/$maxRetries -- regenerating Kerberos key and re-registering in AD..."

                az storage account keys renew `
                    --account-name $witnessStgName -g $rgIdentity `
                    --key key1 --key-type kerb -o none 2>&1
                $kerbKey = (az storage account keys list `
                    --account-name $witnessStgName -g $rgIdentity `
                    --query "[?keyName=='kerb1'].value" -o tsv 2>&1).Trim()

                if ([string]::IsNullOrWhiteSpace($kerbKey)) {
                    Write-Fail "Could not retrieve new Kerberos key. Aborting verification."
                    break
                }

                # Re-run the AD registration script with the fresh key
                $retryScriptContent = Get-Content $adScriptPath -Raw
                $retryScriptContent = $retryScriptContent -replace '(?s)<#.*?#>\s*', ''
                $retryScriptContent = $retryScriptContent -replace '(?sm)param\s*\(.*?^\)\s*', ''
                $retryPreamble = @"
`$StorageAccountName = '$($witnessStgName -replace "'","''")'
`$StorageKerbKey = '$($kerbKey -replace "'","''")'
`$DomainName = '$($DomainName -replace "'","''")'
`$OUPath = '$($ouPath -replace "'","''")'

"@
                $retryScriptContent = $retryPreamble + $retryScriptContent
                $retryScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) `
                    "Register-WitnessInAD-retry-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
                $retryScriptContent | Set-Content -Path $retryScriptPath -Encoding UTF8 -NoNewline

                $retryResult = az vm run-command invoke `
                    -g $rgIdentity -n $dcVmName `
                    --command-id RunPowerShellScript `
                    --scripts "@$retryScriptPath" `
                    --query "value[0].message" -o tsv 2>&1
                Remove-Item $retryScriptPath -Force -ErrorAction SilentlyContinue

                if ($retryResult -notmatch 'AD_REGISTRATION_RESULT=') {
                    Write-Fail "AD re-registration failed on DC01."
                    $retryResult -split "`n" | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
                    break
                }
                Write-Ok "AD re-registration succeeded"

                # Restart KDC on both DCs
                az vm run-command invoke -g $rgIdentity -n $dcVmName `
                    --command-id RunPowerShellScript `
                    --scripts "Restart-Service kdc -Force" `
                    --query "value[0].message" -o tsv 2>&1 | Out-Null
                az vm run-command invoke -g $rgIdentity -n $dc02VmName `
                    --command-id RunPowerShellScript `
                    --scripts "Restart-Service kdc -Force" `
                    --query "value[0].message" -o tsv 2>&1 | Out-Null
                Write-Ok "KDC restarted on both DCs"

                Start-Sleep -Seconds 5
            }

            # -- Run the mount test -----------------------------------------------
            $kerbVerifyContent | Set-Content -Path $kerbVerifyScript -Encoding UTF8 -NoNewline

            Write-Step "$(if ($attempt -eq 0) { 'Testing' } else { 'Re-testing' }) Kerberos SMB mount from $testVm..."
            $verifyResult = az vm run-command invoke `
                -g $testRg -n $testVm `
                --command-id RunPowerShellScript `
                --scripts "@$kerbVerifyScript" `
                --query "value[0].message" -o tsv 2>&1

            if ($verifyResult -match 'MOUNT_EXIT=0') {
                Write-Ok "Kerberos SMB mount verified -- File Share Witness is ready for WSFC quorum"
                $kerbVerified = $true
                break
            }

            if ($attempt -lt $maxRetries) {
                Write-Fail "Mount failed (AES-256 key mismatch likely) -- will retry with fresh key"
            } else {
                Write-Fail "Mount failed after $($maxRetries + 1) attempts"
            }
            $verifyResult -split "`n" | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
        }

        Remove-Item $kerbVerifyScript -Force -ErrorAction SilentlyContinue

        if (-not $kerbVerified) {
            Write-Host ""
            Write-Host "   WARNING: Kerberos SMB verification failed." -ForegroundColor Red
            Write-Host "   Debug steps:" -ForegroundColor Yellow
            Write-Host "     1. RDP to $testVm: net use Z: \\$witnessStgName.file.core.windows.net\witness" -ForegroundColor Gray
            Write-Host "     2. On DC01: Get-ADComputer -Filter {SamAccountName -like '$($witnessStgName.Substring(0,[Math]::Min(15,$witnessStgName.Length)))*'} -Properties userPrincipalName, msDS-SupportedEncryptionTypes, PasswordLastSet | Format-List" -ForegroundColor Gray
            Write-Host "     3. Re-run: .\Register-WitnessStorage.ps1 -BaseName $BaseName -Force" -ForegroundColor Gray
        }
    }
}

# =============================================================================
# 10. Re-disable shared key access
# =============================================================================
Write-Step "Re-disabling shared key data-plane access..."
az storage account update `
    --name $witnessStgName -g $rgIdentity `
    --allow-shared-key-access false -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Warning: failed to re-disable shared key access. Disable manually:" -ForegroundColor Yellow
    Write-Host "   az storage account update --name $witnessStgName -g $rgIdentity --allow-shared-key-access false" -ForegroundColor Gray
} else {
    Write-Ok "Shared key data-plane access re-disabled"
}

# =============================================================================
# Done
# =============================================================================
Write-Header "Witness Storage Registration Complete!"
Write-Host ""
Write-Host "  Storage Account : $witnessStgName" -ForegroundColor White
Write-Host "  Computer Account: $($adInfo.computerName)" -ForegroundColor White
Write-Host "  SPN             : $($adInfo.spn)" -ForegroundColor White
Write-Host "  Domain          : $DomainName" -ForegroundColor White
Write-Host ""
Write-Host "  Next: Configure WSFC quorum on the failover cluster:" -ForegroundColor Cyan
Write-Host "    Set-ClusterQuorum -Cluster <ClusterName> -FileShareWitness ""\\$witnessStgName.file.core.windows.net\witness""" -ForegroundColor Gray
Write-Host ""

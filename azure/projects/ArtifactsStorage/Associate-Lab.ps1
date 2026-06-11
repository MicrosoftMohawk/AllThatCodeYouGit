<#
.SYNOPSIS
    Artifacts Storage — Re-Associate with a Re-Deployed Lab
    Wires an existing artifacts deployment to a newly deployed lab whose
    -BaseName may differ from the original, and grants RBAC to your UPN.

.DESCRIPTION
    Discovers an existing artifacts deployment (by -NamePrefix) and a newly
    deployed lab (by -LabBaseName), then deploys a Bicep module that
    additively adds:

      * A new VNet link on the artifacts private DNS zone
        (privatelink.file.core.windows.net) pointing at the new lab VNet
      * A new Private Endpoint into the new lab's snet-pe subnet
      * Storage File Data Privileged Contributor on the storage account
        for your UPN (or another principal)
      * Reader on the artifacts resource group for the same principal

    Then (unless -SkipADDS) re-registers the storage account as a computer
    object in the new lab's Active Directory so domain-joined VMs in the
    new lab can mount the share via Kerberos.  Finally (unless
    -SkipVerification) it tests an SMB mount from a domain-joined VM in
    the new lab.

    The original PE / DNS link / AD-DS registration from the previous lab
    are left in place — this script is additive and idempotent.

.PARAMETER NamePrefix
    Name prefix of the existing artifacts deployment (e.g. "artifacts").
    Used to locate the resource group "<NamePrefix>-rg-artifacts".

.PARAMETER LabBaseName
    Base name of the newly deployed lab (e.g. "azlab2").  Used to locate
    "<LabBaseName>-rg-network" / "<LabBaseName>-vnet" / "snet-pe" and
    "<LabBaseName>-rg-identity" / "<LabBaseName>-dc01" / "-dc02".

.PARAMETER UserUpn
    UPN of the user to grant RBAC to.  Defaults to the currently signed-in
    Azure CLI user.

.PARAMETER DomainName
    FQDN of the new lab's AD domain (e.g. azlab2.local).  Auto-queried
    from the new DC01 if omitted.

.PARAMETER TestVm
    Name of a domain-joined VM in the new lab to use for SMB mount
    verification.  Defaults to "<LabBaseName>-cas" with fallback to
    "<LabBaseName>-dc01".

.PARAMETER SubscriptionId
    Target subscription ID.  If not set, uses current az CLI default.

.PARAMETER SkipADDS
    Skip re-registering the storage account in the new lab's AD.  Use this
    if the storage account is already correctly registered, or if you do
    not need Kerberos SMB from domain-joined VMs.

.PARAMETER SkipVerification
    Skip the SMB mount verification from -TestVm.

.PARAMETER Force
    Override the region-mismatch safety check.  If the existing artifacts
    storage account is in a different Azure region than the new lab VNet,
    the script will normally STOP and recommend deploying a fresh artifacts
    in the lab's region (then copying data via Copy-ArtifactsShare.ps1).
    Pass -Force to proceed with a cross-region Private Endpoint anyway.
    Cross-region PEs work but add latency, incur bandwidth charges, and
    prevent ever decommissioning the old region cleanly.

.PARAMETER WhatIf
    Run "az deployment group what-if" instead of deploying.

.EXAMPLE
    # Re-associate the "artifacts" deployment with the new "azlab2" lab
    # using the signed-in user (same region only)
    .\Associate-Lab.ps1 -NamePrefix artifacts -LabBaseName azlab2

.EXAMPLE
    # Grant RBAC to a different user, skip AD re-registration
    .\Associate-Lab.ps1 -NamePrefix artifacts -LabBaseName azlab2 `
        -UserUpn jane@contoso.com -SkipADDS

.EXAMPLE
    # Preview the changes without deploying
    .\Associate-Lab.ps1 -NamePrefix artifacts -LabBaseName azlab2 -WhatIf

.EXAMPLE
    # Force cross-region association (latency + bandwidth implications)
    .\Associate-Lab.ps1 -NamePrefix artifacts -LabBaseName azlab2 -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$NamePrefix,

    [Parameter(Mandatory = $true)]
    [string]$LabBaseName,

    [string]$UserUpn,

    [string]$DomainName,

    [string]$TestVm,

    [string]$SubscriptionId,

    [switch]$SkipADDS,

    [switch]$SkipVerification,

    # Override the region-mismatch safety check.  If the existing artifacts
    # storage account is in a different Azure region than the new lab VNet,
    # the script will normally STOP and recommend deploying a fresh artifacts
    # in the lab's region (then copying data via Copy-ArtifactsShare.ps1).
    # Use -Force to override and create a cross-region Private Endpoint
    # anyway.  Cross-region PEs work but add latency and inter-region
    # bandwidth charges, and they prevent you from ever cleanly
    # decommissioning the old region.
    [switch]$Force,

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

# =============================================================================
# Helpers (match deploy.ps1 style)
# =============================================================================
function Write-Header { param([string]$Message) Write-Host "`n============================================================" -ForegroundColor Cyan; Write-Host "  $Message" -ForegroundColor Cyan; Write-Host "============================================================" -ForegroundColor Cyan }
function Write-Step   { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Yellow }
function Write-Ok     { param([string]$Message) Write-Host "   [OK] $Message" -ForegroundColor Green }
function Write-Fail   { param([string]$Message) Write-Host "   [FAIL] $Message" -ForegroundColor Red }

# =============================================================================
# 1. Prerequisite Checks
# =============================================================================
Write-Header "Artifacts Storage — Associate With Re-Deployed Lab"

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

# --- Bicep CLI ----------------------------------------------------------------
Write-Step "Checking Bicep CLI..."
try {
    $bicepVersion = az bicep version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Bicep not installed" }
    Write-Ok $bicepVersion
} catch {
    Write-Host "   Bicep CLI not found. Installing..." -ForegroundColor Yellow
    az bicep install
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to install Bicep CLI."; exit 1 }
    Write-Ok "Bicep CLI installed"
}

# --- Login session ------------------------------------------------------------
Write-Step "Checking Azure login session..."
try {
    # Validate both ARM and Graph tokens (Graph is needed for az ad lookups).
    $tokenJson = az account get-access-token 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ARM token expired" }
    $graphCheck = az account get-access-token --resource https://graph.microsoft.com 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Graph token expired" }
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Ok "Logged in as $($account.user.name) (tenant: $($account.tenantId))"
    Write-Host ""
    Write-Host "   [1] Continue with this account" -ForegroundColor White
    Write-Host "   [2] Log in with a different account" -ForegroundColor White
    $choice = Read-Host "   Select (default: 1)"
    if ($choice -eq '2') {
        az login | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Fail "Login failed."; exit 1 }
        $account = az account show 2>&1 | ConvertFrom-Json
        Write-Ok "Now logged in as $($account.user.name)"
    }
} catch {
    Write-Host "   Session expired or invalid. Opening browser login..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) { Write-Fail "Login failed."; exit 1 }
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Ok "Logged in as $($account.user.name)"
}

# --- Subscription selection ---------------------------------------------------
if ($SubscriptionId) {
    Write-Step "Setting subscription to $SubscriptionId..."
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to set subscription."; exit 1 }
    $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
    Write-Ok "$($currentSub.name) ($($currentSub.id))"
} else {
    Write-Step "Detecting current subscription..."
    $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
    Write-Ok "Current subscription: $($currentSub.name) ($($currentSub.id))"
    Write-Host ""
    Write-Host "   [1] Continue with this subscription" -ForegroundColor White
    Write-Host "   [2] Choose a different subscription" -ForegroundColor White
    $subChoice = Read-Host "   Select (default: 1)"
    if ($subChoice -eq '2') {
        $subs = az account list --query "[?state=='Enabled'].{name:name, id:id}" -o json | ConvertFrom-Json
        if (-not $subs -or $subs.Count -eq 0) { Write-Fail "No enabled subscriptions found."; exit 1 }
        Write-Host ""
        for ($i = 0; $i -lt $subs.Count; $i++) {
            $marker = if ($subs[$i].id -eq $currentSub.id) { ' (current)' } else { '' }
            Write-Host "   [$($i + 1)] $($subs[$i].name) — $($subs[$i].id)$marker" -ForegroundColor White
        }
        Write-Host ""
        $subIndex = Read-Host "   Enter number (1-$($subs.Count))"
        $idx = 0
        if (-not [int]::TryParse($subIndex, [ref]$idx) -or $idx -lt 1 -or $idx -gt $subs.Count) { Write-Fail "Invalid selection."; exit 1 }
        az account set --subscription $subs[$idx - 1].id
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to set subscription."; exit 1 }
        $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
        Write-Ok "Subscription set to: $($currentSub.name) ($($currentSub.id))"
    }
}

# =============================================================================
# 2. Resolve the artifacts deployment
# =============================================================================
Write-Step "Resolving artifacts deployment for '$NamePrefix'..."

$rgName = "$NamePrefix-rg-artifacts"
$rgExists = az group exists --name $rgName 2>&1
if ($rgExists -ne 'true') {
    Write-Fail "Artifacts resource group '$rgName' not found. Deploy it first with deploy.ps1."
    exit 1
}
Write-Ok "Resource group: $rgName"

# Pick the storage account in the artifacts RG (deploy.ps1 only creates one).
$stgAccounts = az storage account list --resource-group $rgName --query "[].name" -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($stgAccounts)) {
    Write-Fail "No storage accounts found in '$rgName'."
    exit 1
}
$stgAccountList = @($stgAccounts -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
if ($stgAccountList.Count -gt 1) {
    Write-Fail "Multiple storage accounts found in '$rgName': $($stgAccountList -join ', '). Cannot disambiguate."
    exit 1
}
$stgName = $stgAccountList[0]
Write-Ok "Storage account: $stgName"

# Resolve the storage account's location for the new Private Endpoint.
$stgLocation = az storage account show --name $stgName --resource-group $rgName --query location -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($stgLocation)) {
    Write-Fail "Could not retrieve storage account location."
    exit 1
}
$stgLocation = $stgLocation.Trim()
Write-Ok "Location: $stgLocation"

# Confirm the private DNS zone exists in the artifacts RG (the module
# references it as an `existing` resource — fail fast with a clear error).
$dnsZoneName = 'privatelink.file.core.windows.net'
$dnsZoneCheck = az network private-dns zone show --resource-group $rgName --name $dnsZoneName --query name -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dnsZoneCheck)) {
    Write-Fail "Private DNS zone '$dnsZoneName' not found in '$rgName'."
    Write-Host "   The original artifacts deployment must include the DNS zone — was the RG modified manually?" -ForegroundColor Yellow
    exit 1
}
Write-Ok "DNS zone: $dnsZoneName"

# =============================================================================
# 3. Resolve the new lab VNet and PE subnet
# =============================================================================
Write-Step "Resolving new lab VNet '$LabBaseName-vnet'..."

$labRgNetwork  = "$LabBaseName-rg-network"
$labVnetName   = "$LabBaseName-vnet"
$labRgIdentity = "$LabBaseName-rg-identity"
$labRgMain     = "$LabBaseName-rg-main"
$dcVmName      = "$LabBaseName-dc01"
$dc02VmName    = "$LabBaseName-dc02"

$newLabVnetId = az network vnet show -g $labRgNetwork -n $labVnetName --query id -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newLabVnetId)) {
    Write-Fail "Could not find VNet '$labVnetName' in '$labRgNetwork'. Verify the new lab is deployed with -BaseName $LabBaseName."
    exit 1
}
$newLabVnetId = $newLabVnetId.Trim()
Write-Ok "VNet: $newLabVnetId"

# Capture the new lab VNet's region — the Private Endpoint MUST be created in
# the same region as the VNet/subnet, not the storage account's region.
# Mismatched regions surface as a misleading "VNet not found" error from the
# PE provider.
$newLabVnetLocation = az network vnet show -g $labRgNetwork -n $labVnetName --query location -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newLabVnetLocation)) {
    Write-Fail "Could not determine region of VNet '$labVnetName'."
    exit 1
}
$newLabVnetLocation = $newLabVnetLocation.Trim()
Write-Ok "VNet region: $newLabVnetLocation"

# =============================================================================
# Region-mismatch guardrail
#
# If the existing artifacts storage account is in a different Azure region
# than the new lab's VNet, re-associating it (i.e. adding a cross-region
# Private Endpoint) is almost always the wrong call:
#   - It works, but adds inter-region latency to every SMB read/write.
#   - It incurs cross-region bandwidth charges.
#   - It leaves you with two regions to manage forever.
#   - You can't cleanly decommission the old region.
#
# The correct workflow when regions differ is:
#   1. Deploy a NEW artifacts in the lab's region.
#   2. Migrate the file share contents (server-side AzCopy).
#   3. Associate the NEW (same-region) artifacts with the lab.
#   4. Destroy the old artifacts deployment.
#
# We stop here and print the exact commands.  -Force overrides this and
# proceeds with the cross-region PE if that's really what you want.
# =============================================================================
if ($newLabVnetLocation -ne $stgLocation) {
    if ($Force) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "   !! REGION MISMATCH (proceeding because -Force was specified) !!" -ForegroundColor Yellow
        Write-Host "   Storage account region : $stgLocation" -ForegroundColor Yellow
        Write-Host "   New lab VNet region    : $newLabVnetLocation" -ForegroundColor Yellow
        Write-Host "   A cross-region Private Endpoint will be created in '$newLabVnetLocation'." -ForegroundColor Yellow
        Write-Host "   Expect inter-region latency + bandwidth charges." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
    } else {
        $newArtifactsPrefix = "$LabBaseName".Substring(0, [Math]::Min(7, $LabBaseName.Length)) + "art"
        if ($newArtifactsPrefix.Length -gt 10) { $newArtifactsPrefix = $newArtifactsPrefix.Substring(0, 10) }

        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "  REGION MISMATCH DETECTED — Association stopped" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Existing artifacts ($NamePrefix)" -ForegroundColor White
        Write-Host "    Resource group : $rgName" -ForegroundColor Gray
        Write-Host "    Storage account: $stgName" -ForegroundColor Gray
        Write-Host "    Region         : $stgLocation" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  New lab ($LabBaseName)" -ForegroundColor White
        Write-Host "    VNet           : $labVnetName" -ForegroundColor Gray
        Write-Host "    Region         : $newLabVnetLocation" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Re-attaching the existing (cross-region) artifacts is not recommended:" -ForegroundColor Yellow
        Write-Host "    - Cross-region SMB adds latency to every read/write." -ForegroundColor Gray
        Write-Host "    - You pay inter-region bandwidth on every file access." -ForegroundColor Gray
        Write-Host "    - You can't ever decommission the old region cleanly." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  RECOMMENDED WORKFLOW — stand up a same-region artifacts and migrate data:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    # 1. Deploy a NEW artifacts in the lab's region ($newLabVnetLocation):" -ForegroundColor Gray
        Write-Host "    .\deploy.ps1 ``" -ForegroundColor White
        Write-Host "        -NamePrefix $newArtifactsPrefix ``" -ForegroundColor White
        Write-Host "        -Location $newLabVnetLocation ``" -ForegroundColor White
        Write-Host "        -LabBaseName $LabBaseName" -ForegroundColor White
        Write-Host ""
        Write-Host "    # 2. Copy file share contents from old -> new (server-side AzCopy):" -ForegroundColor Gray
        Write-Host "    .\Copy-ArtifactsShare.ps1 ``" -ForegroundColor White
        Write-Host "        -SourceNamePrefix $NamePrefix ``" -ForegroundColor White
        Write-Host "        -TargetNamePrefix $newArtifactsPrefix" -ForegroundColor White
        Write-Host ""
        Write-Host "    # 3. (Optional) Verify content from a lab VM, then destroy the old:" -ForegroundColor Gray
        Write-Host "    .\deploy.ps1 -NamePrefix $NamePrefix -Destroy" -ForegroundColor White
        Write-Host ""
        Write-Host "  ALTERNATIVE — proceed with a cross-region Private Endpoint anyway:" -ForegroundColor Cyan
        Write-Host "    .\Associate-Lab.ps1 -NamePrefix $NamePrefix -LabBaseName $LabBaseName -Force" -ForegroundColor White
        Write-Host ""
        exit 0
    }
}

$newPeSubnetId = az network vnet subnet show -g $labRgNetwork --vnet-name $labVnetName -n snet-pe --query id -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newPeSubnetId)) {
    Write-Fail "Could not find subnet 'snet-pe' in VNet '$labVnetName'."
    exit 1
}
$newPeSubnetId = $newPeSubnetId.Trim()
Write-Ok "PE subnet: $newPeSubnetId"

# =============================================================================
# 3a. Detect an existing privatelink.file.<suffix> zone linked to the new VNet
# Azure forbids linking the same VNet to two zones with the same name, so if
# the new lab already has one (e.g. for its own witness storage), we must
# (a) skip creating a new link in the artifacts zone, and (b) register the
# new PE's A record in that existing zone instead.
# =============================================================================
Write-Step "Checking for an existing 'privatelink.file.core.windows.net' zone linked to '$labVnetName'..."

function Find-LinkedPrivateDnsZone {
    param([string]$ZoneName, [string]$VNetId)
    if ([string]::IsNullOrWhiteSpace($VNetId)) { return '' }

    $zonesJson = az network private-dns zone list `
        --query "[?name=='$ZoneName'].{id:id, rg:resourceGroup}" -o json 2>&1
    if ($LASTEXITCODE -ne 0) { return '' }
    $zones = $null
    try { $zones = $zonesJson | ConvertFrom-Json } catch { return '' }
    if (-not $zones -or $zones.Count -eq 0) { return '' }

    foreach ($zone in $zones) {
        $linkedId = az network private-dns link vnet list `
            --zone-name $ZoneName --resource-group $zone.rg `
            --query "[?virtualNetwork.id=='$VNetId'].id" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($linkedId)) {
            return $zone.id.Trim()
        }
    }
    return ''
}

$existingFileZoneId = Find-LinkedPrivateDnsZone -ZoneName 'privatelink.file.core.windows.net' -VNetId $newLabVnetId
$createDnsLink = $true
$targetDnsZoneId = ''
if (-not [string]::IsNullOrWhiteSpace($existingFileZoneId)) {
    $createDnsLink   = $false
    $targetDnsZoneId = $existingFileZoneId
    Write-Ok "Found existing linked zone — will register new PE there and skip artifacts-zone link"
    Write-Host "   Zone: $existingFileZoneId" -ForegroundColor Gray
} else {
    Write-Ok "No existing linked zone — artifacts zone will be linked to '$labVnetName'"
}

# =============================================================================
# 4. Resolve the principal (UPN -> object ID)
# =============================================================================
Write-Step "Resolving principal for RBAC assignment..."

if ([string]::IsNullOrWhiteSpace($UserUpn)) {
    $UserUpn = $account.user.name
    Write-Host "   Using signed-in user: $UserUpn" -ForegroundColor Gray
}
$UserUpn = $UserUpn.Trim()

# Prefer signed-in-user lookup if the supplied UPN matches the active session
# (avoids Graph lookup issues with B2B guest / MSA accounts).
if ($account -and $account.user.name -eq $UserUpn) {
    $principalId = az ad signed-in-user show --query id -o tsv 2>&1
} else {
    $principalId = az ad user show --id $UserUpn --query id -o tsv 2>&1
}
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
    Write-Fail "Could not resolve UPN '$UserUpn' in Entra ID."
    exit 1
}
$principalId = ("$principalId").Trim()
Write-Ok "Principal: $UserUpn -> $principalId"

# =============================================================================
# 5. Compile + (optionally) what-if + deploy the Bicep module
# =============================================================================
$templateFile = Join-Path $ScriptRoot 'modules' 'labAssociation.bicep'
if (-not (Test-Path $templateFile)) {
    Write-Fail "Module not found: $templateFile"
    exit 1
}

Write-Step "Compiling Bicep module..."
az bicep build --file $templateFile 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Bicep compilation failed. Run: az bicep build --file $templateFile"
    exit 1
}
Write-Ok "Module compiled"

$deployParams = @(
    "storageAccountName=$stgName"
    "newLabBaseName=$LabBaseName"
    "newLabVnetId=$newLabVnetId"
    "newPeSubnetId=$newPeSubnetId"
    "location=$newLabVnetLocation"
    "createDnsLink=$($createDnsLink.ToString().ToLower())"
    "targetDnsZoneId=$targetDnsZoneId"
)

Write-Header "Association Deployment Summary"
Write-Host "  Artifacts RG       : $rgName" -ForegroundColor White
Write-Host "  Storage Account    : $stgName ($stgLocation)" -ForegroundColor White
Write-Host "  New Lab BaseName   : $LabBaseName" -ForegroundColor White
Write-Host "  New Lab VNet       : $newLabVnetId" -ForegroundColor White
Write-Host "  New Lab Region     : $newLabVnetLocation $(if ($newLabVnetLocation -ne $stgLocation) { '(differs from storage region)' })" -ForegroundColor White
Write-Host "  New Lab PE Subnet  : $newPeSubnetId" -ForegroundColor White
Write-Host "  DNS link strategy  : $(if ($createDnsLink) { 'Link artifacts zone to new VNet' } else { 'Use existing zone (see above)' })" -ForegroundColor White
Write-Host "  Principal          : $UserUpn ($principalId)" -ForegroundColor White
Write-Host "  RBAC (post-deploy) : Storage File Data Privileged Contributor (on storage account)" -ForegroundColor White
Write-Host "                       Reader (on $rgName)" -ForegroundColor White
Write-Host "  AD DS re-register  : $(if ($SkipADDS) { 'SKIPPED (-SkipADDS)' } else { 'Yes (against new DC01)' })" -ForegroundColor White
Write-Host "  Mount verification : $(if ($SkipVerification) { 'SKIPPED (-SkipVerification)' } else { 'Yes' })" -ForegroundColor White

if ($WhatIf) {
    Write-Header "What-If — previewing changes"
    az deployment group what-if `
        --resource-group $rgName `
        --template-file $templateFile `
        --parameters @deployParams
    Write-Host ""
    Write-Host "   What-If complete. Re-run without -WhatIf to apply." -ForegroundColor Yellow
    exit 0
}

Write-Header "Starting Association Deployment"
$deploymentName = "$NamePrefix-associate-$LabBaseName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

az deployment group create `
    --name $deploymentName `
    --resource-group $rgName `
    --template-file $templateFile `
    --parameters @deployParams `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Association deployment failed. Inspect with:"
    Write-Host "   az deployment group show --name $deploymentName -g $rgName --query properties.error" -ForegroundColor Gray
    exit 1
}

# Retrieve outputs.
$outputs = az deployment group show --name $deploymentName -g $rgName --query "properties.outputs" -o json 2>&1 | ConvertFrom-Json
$newPeName  = $outputs.newPrivateEndpointName.value
$newPeIp    = $outputs.newPrivateEndpointIp.value
$newLinkNm  = if ($outputs.newDnsVnetLinkName) { $outputs.newDnsVnetLinkName.value } else { '' }
$effZoneId  = if ($outputs.effectiveDnsZoneId)  { $outputs.effectiveDnsZoneId.value }  else { '' }
Write-Ok "New Private Endpoint: $newPeName ($newPeIp)"
if (-not [string]::IsNullOrWhiteSpace($newLinkNm)) {
    Write-Ok "New DNS VNet link   : $newLinkNm"
} else {
    Write-Ok "DNS link            : reused existing zone link (no new link created)"
}
Write-Ok "PE registered in    : $effZoneId"

# =============================================================================
# 5b. RBAC — idempotent assignment via az CLI
# az role assignment create returns success without error when an identical
# assignment exists (or fails with RoleAssignmentExists which we swallow), so
# this is safe to re-run.  Done in PowerShell rather than Bicep because
# Bicep's roleAssignments resource hard-fails when an equivalent assignment
# already exists with a different GUID (e.g. created by the original deploy).
# =============================================================================
Write-Step "Granting RBAC to '$UserUpn' (idempotent)..."

function Set-RbacAssignmentIdempotent {
    param(
        [string]$Scope,
        [string]$RoleId,
        [string]$RoleLabel,
        [string]$PrincipalObjectId
    )
    $existing = az role assignment list `
        --scope $Scope --role $RoleId `
        --assignee-object-id $PrincipalObjectId `
        --query "[].id" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Ok "$RoleLabel — already present"
        return
    }
    $createOut = az role assignment create `
        --scope $Scope --role $RoleId `
        --assignee-object-id $PrincipalObjectId `
        --assignee-principal-type User `
        -o none 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$RoleLabel — created"
    } elseif ("$createOut" -match 'RoleAssignmentExists|already exists') {
        Write-Ok "$RoleLabel — already present (race / pre-existing)"
    } else {
        Write-Fail "$RoleLabel — failed to create"
        Write-Host "   $createOut" -ForegroundColor Gray
    }
}

$stgScope = az storage account show -g $rgName -n $stgName --query id -o tsv 2>&1
$stgScope = ("$stgScope").Trim()
$rgScope  = az group show -n $rgName --query id -o tsv 2>&1
$rgScope  = ("$rgScope").Trim()

# Storage File Data Privileged Contributor (69566ab7-960f-475b-8e7c-b3118f30c6bd)
Set-RbacAssignmentIdempotent -Scope $stgScope `
    -RoleId '69566ab7-960f-475b-8e7c-b3118f30c6bd' `
    -RoleLabel 'Storage File Data Privileged Contributor (storage account)' `
    -PrincipalObjectId $principalId

# Reader (acdd72a7-3385-48ef-bd42-f606fba81ae7)
Set-RbacAssignmentIdempotent -Scope $rgScope `
    -RoleId 'acdd72a7-3385-48ef-bd42-f606fba81ae7' `
    -RoleLabel "Reader ($rgName)" `
    -PrincipalObjectId $principalId

# =============================================================================
# 6. AD DS Re-Registration against the new lab's DC01
# =============================================================================
if ($SkipADDS) {
    Write-Header "AD DS Re-Registration — SKIPPED (-SkipADDS)"
} else {
    Write-Header "AD DS Re-Registration — New Lab '$LabBaseName'"

    # --- Confirm the new identity RG and DC01 exist ---
    $rgIdentityExists = az group exists --name $labRgIdentity 2>&1
    if ($rgIdentityExists -ne 'true') {
        Write-Fail "Identity resource group '$labRgIdentity' not found. Cannot re-register in AD."
        Write-Host "   Re-run with -SkipADDS, or deploy the lab with Tier >= 1 first." -ForegroundColor Yellow
        exit 1
    }

    # --- Derive / query the new domain name ---
    if ([string]::IsNullOrWhiteSpace($DomainName)) {
        Write-Step "Querying $dcVmName for domain information..."
        # Avoid parentheses in --scripts — az.cmd shells through cmd.exe and
        # parentheses break command parsing.
        $domainQuery = az vm run-command invoke `
            --resource-group $labRgIdentity `
            --name $dcVmName `
            --command-id RunPowerShellScript `
            --scripts "Get-ADDomain | Select-Object -ExpandProperty DnsRoot" `
            --query "value[0].message" -o tsv 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Could not query $dcVmName in $labRgIdentity."
            Write-Host "   Ensure DC01 is running, or pass -DomainName explicitly." -ForegroundColor Yellow
            exit 1
        }
        $DomainName = ($domainQuery -split "`n" | Where-Object { $_ -match '\.' -and $_ -notmatch '^\[' }).Trim()
        if ([string]::IsNullOrWhiteSpace($DomainName)) {
            Write-Fail "Could not parse domain name from $dcVmName output."
            exit 1
        }
        Write-Ok "Domain (queried from $dcVmName): $DomainName"
    } else {
        Write-Ok "Domain (from parameter): $DomainName"
    }

    # --- Generate a fresh Kerberos key on the storage account ---
    Write-Step "Generating fresh Kerberos key on $stgName..."

    # AD DS auth uses the kerb key to set the computer-account password —
    # temporarily enable shared key access so we can rotate and retrieve it.
    az storage account update `
        --name $stgName --resource-group $rgName `
        --allow-shared-key-access true -o none 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to temporarily enable shared key access."; exit 1 }

    az storage account keys renew `
        --account-name $stgName --resource-group $rgName `
        --key key1 --key-type kerb -o none 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to renew Kerberos key."; exit 1 }

    $kerbKey = az storage account keys list `
        --account-name $stgName --resource-group $rgName `
        --query "[?keyName=='kerb1'].value" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kerbKey)) {
        Write-Fail "Could not retrieve new Kerberos key."
        exit 1
    }
    $kerbKey = $kerbKey.Trim()
    Write-Ok "Kerberos key (kerb1) rotated"

    # --- Register the storage account in the new lab's AD ---
    Write-Step "Registering $stgName in '$DomainName' on $dcVmName..."

    $adScriptPath = Join-Path $ScriptRoot 'scripts' 'Register-StorageInAD.ps1'
    if (-not (Test-Path $adScriptPath)) {
        Write-Fail "AD registration script not found: $adScriptPath"
        exit 1
    }

    # Strip <# #> comment block + param() block — cmd.exe via az run-command
    # corrupts <# #> blocks and --parameters doesn't reliably bind to
    # PowerShell param() inputs when invoked with @file.
    $adScriptContent = Get-Content $adScriptPath -Raw
    $adScriptContent = $adScriptContent -replace '(?s)<#.*?#>\s*', ''
    $adScriptContent = $adScriptContent -replace '(?sm)param\s*\(.*?^\)\s*', ''

    $domainDNParts = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','
    $ouPath = "OU=Storage Accounts,OU=Lab Servers,$domainDNParts"
    $preamble = @"
`$StorageAccountName = '$($stgName -replace "'","''")'
`$StorageKerbKey = '$($kerbKey -replace "'","''")'
`$DomainName = '$($DomainName -replace "'","''")'
`$OUPath = '$($ouPath -replace "'","''")'

"@
    $adScriptContent = $preamble + $adScriptContent

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) `
        "Register-StorageInAD-assoc-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
    $adScriptContent | Set-Content -Path $tempScript -Encoding UTF8 -NoNewline

    $adResultRaw = az vm run-command invoke `
        --resource-group $labRgIdentity `
        --name $dcVmName `
        --command-id RunPowerShellScript `
        --scripts "@$tempScript" `
        -o json 2>&1

    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

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
        Write-Fail "AD registration failed on $dcVmName."
        if ($stderr) { Write-Host "   stderr: $stderr" -ForegroundColor Gray }
        if ($stdout) { Write-Host "   stdout: $stdout" -ForegroundColor Gray }
        exit 1
    }

    $jsonMatch = [regex]::Match($stdout, 'AD_REGISTRATION_RESULT=(.+)')
    if (-not $jsonMatch.Success) {
        Write-Fail "Could not parse AD registration output."
        Write-Host "   --- DC stdout ---" -ForegroundColor Gray
        if ($stdout) { ($stdout -split "`n") | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray } }
        Write-Host "   --- DC stderr ---" -ForegroundColor Gray
        if ($stderr) { ($stderr -split "`n") | ForEach-Object { Write-Host "   $_" -ForegroundColor Red } }
        exit 1
    }

    try {
        $adInfo = $jsonMatch.Groups[1].Value | ConvertFrom-Json
    } catch {
        Write-Fail "Failed to parse AD registration JSON."
        Write-Host "   captured: $($jsonMatch.Groups[1].Value)" -ForegroundColor Gray
        exit 1
    }
    Write-Ok "Computer account: $($adInfo.computerName)"
    Write-Ok "SPN             : $($adInfo.spn)"
    Write-Ok "Azure Storage SID: $($adInfo.azureStorageSid)"

    # --- Update the storage account with the new AD DS configuration ---
    Write-Step "Updating $stgName with new AD DS identity configuration..."
    az storage account update `
        --name $stgName --resource-group $rgName `
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
        Write-Fail "Failed to update storage account with AD DS configuration."
        exit 1
    }
    Write-Ok "Storage account re-bound to '$DomainName'"

    # --- Restart KDC on new DC02 to flush cached key material ---
    $dc02Exists = az vm show -g $labRgIdentity -n $dc02VmName --query name -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($dc02Exists)) {
        Write-Step "Flushing KDC cache on $dc02VmName..."
        az vm run-command invoke `
            --resource-group $labRgIdentity `
            --name $dc02VmName `
            --command-id RunPowerShellScript `
            --scripts "Restart-Service kdc -Force; Write-Host 'KDC restarted'" `
            --query "value[0].message" -o tsv 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$dc02VmName KDC cache flushed"
        } else {
            Write-Host "   Warning: could not restart KDC on $dc02VmName." -ForegroundColor Yellow
        }
    } else {
        Write-Host "   $dc02VmName not present — skipping DC02 KDC flush." -ForegroundColor Yellow
    }

    # --- Re-disable shared key access ---
    Write-Step "Re-disabling shared key data-plane access..."
    az storage account update `
        --name $stgName --resource-group $rgName `
        --allow-shared-key-access false -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Warning: failed to re-disable shared key access. Disable manually:"
        Write-Host "   az storage account update --name $stgName -g $rgName --allow-shared-key-access false" -ForegroundColor Gray
    } else {
        Write-Ok "Shared key access re-disabled"
    }
}

# =============================================================================
# 7. SMB Mount Verification
# =============================================================================
$shareName = 'artifacts'

if ($SkipVerification) {
    Write-Header "SMB Mount Verification — SKIPPED (-SkipVerification)"
} elseif ($SkipADDS) {
    Write-Header "SMB Mount Verification — SKIPPED (no AD re-registration ran)"
    Write-Host "   Verify manually: net use Z: \\$stgName.file.core.windows.net\$shareName" -ForegroundColor Yellow
} else {
    Write-Header "SMB Mount Verification — Kerberos from new lab"

    # Default test VM: <BaseName>-cas, fallback to <BaseName>-dc01.
    if ([string]::IsNullOrWhiteSpace($TestVm)) {
        $TestVm = "$LabBaseName-cas"
    }

    # Resolve the test VM's RG by checking common lab RGs.
    $testRg = $null
    foreach ($candidate in @($labRgMain, $labRgIdentity)) {
        $exists = az vm show -g $candidate -n $TestVm --query name -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($exists)) {
            $testRg = $candidate
            break
        }
    }

    # Fallback to DC01 if CAS not present.
    if (-not $testRg -and $TestVm -eq "$LabBaseName-cas") {
        $TestVm = $dcVmName
        $testRg = $labRgIdentity
        Write-Host "   '$LabBaseName-cas' not found — falling back to $TestVm." -ForegroundColor Yellow
    }

    if (-not $testRg) {
        Write-Fail "Could not find test VM '$TestVm' in $labRgMain or $labRgIdentity."
        Write-Host "   Verify manually: net use Z: \\$stgName.file.core.windows.net\$shareName" -ForegroundColor Yellow
    } else {
        $testVmState = az vm get-instance-view -g $testRg -n $TestVm `
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" `
            -o tsv 2>&1

        if ($LASTEXITCODE -ne 0 -or $testVmState -notmatch 'running') {
            Write-Host "   VM '$TestVm' not running (state: $testVmState). Skipping mount test." -ForegroundColor Yellow
            Write-Host "   Verify manually: net use Z: \\$stgName.file.core.windows.net\$shareName" -ForegroundColor Yellow
        } else {
            Write-Ok "Test VM: $TestVm ($testRg)"

            $kerbVerifyScript = Join-Path ([System.IO.Path]::GetTempPath()) `
                "Verify-KerbMount-assoc-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
            $kerbVerifyContent = @"
klist purge 2>&1 | Out-Null
net use * /delete /y 2>&1 | Out-Null
Start-Sleep -Seconds 2
`$r = net use Z: "\\$stgName.file.core.windows.net\$shareName" 2>&1
Write-Host "MOUNT_EXIT=`$LASTEXITCODE"
`$r | ForEach-Object { Write-Host `$_ }
net use Z: /delete 2>&1 | Out-Null
"@
            $kerbVerifyContent | Set-Content -Path $kerbVerifyScript -Encoding UTF8 -NoNewline

            Write-Step "Testing Kerberos SMB mount from $TestVm..."
            $verifyResult = az vm run-command invoke `
                -g $testRg -n $TestVm `
                --command-id RunPowerShellScript `
                --scripts "@$kerbVerifyScript" `
                --query "value[0].message" -o tsv 2>&1

            Remove-Item $kerbVerifyScript -Force -ErrorAction SilentlyContinue

            if ($verifyResult -match 'MOUNT_EXIT=0') {
                Write-Ok "Kerberos SMB mount verified from $TestVm"
            } else {
                Write-Fail "Mount failed from $TestVm — AES-256 key mismatch is the usual cause."
                $verifyResult -split "`n" | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
                Write-Host ""
                Write-Host "   Debug:" -ForegroundColor Yellow
                Write-Host "     1. RDP to $TestVm and run: net use Z: \\$stgName.file.core.windows.net\$shareName" -ForegroundColor Gray
                Write-Host "     2. On ${dcVmName}: Get-ADComputer -Filter {SamAccountName -like '$($stgName.Substring(0,15))*'} -Properties msDS-SupportedEncryptionTypes, PasswordLastSet | Format-List" -ForegroundColor Gray
                Write-Host "     3. Re-run this script (a new kerb1 key will be generated)." -ForegroundColor Gray
            }
        }
    }
}

# =============================================================================
# 8. Summary
# =============================================================================
Write-Header "Association Complete!"
Write-Host ""
Write-Host "  Artifacts RG       : $rgName" -ForegroundColor White
Write-Host "  Storage Account    : $stgName" -ForegroundColor White
Write-Host "  Bound to lab       : $LabBaseName" -ForegroundColor White
Write-Host "  New PE / IP        : $newPeName / $newPeIp" -ForegroundColor White
Write-Host "  DNS link           : $(if ([string]::IsNullOrWhiteSpace($newLinkNm)) { 'reused existing zone link' } else { $newLinkNm })" -ForegroundColor White
Write-Host "  PE A-record zone   : $effZoneId" -ForegroundColor White
Write-Host "  Granted to $UserUpn :" -ForegroundColor White
Write-Host "    - Storage File Data Privileged Contributor (on storage account)" -ForegroundColor Gray
Write-Host "    - Reader (on $rgName)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Access (requires connectivity to '$LabBaseName' VNet, e.g. via VPN):" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  From your workstation (OAuth/MFA):" -ForegroundColor White
Write-Host "    az storage file list --account-name $stgName --share-name $shareName --auth-mode login -o table" -ForegroundColor Gray
Write-Host "    az storage file upload --account-name $stgName --share-name $shareName --source <file> --auth-mode login" -ForegroundColor Gray
Write-Host ""
Write-Host "  From a domain-joined VM in '$LabBaseName' (Kerberos SMB):" -ForegroundColor White
Write-Host "    net use Z: \\$stgName.file.core.windows.net\$shareName" -ForegroundColor Gray
Write-Host ""

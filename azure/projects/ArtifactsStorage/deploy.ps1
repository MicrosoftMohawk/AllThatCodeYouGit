<#
.SYNOPSIS
    Artifacts Storage — Deployment Wrapper Script
    Deploys a private Azure Files share for lab artifact storage.

.DESCRIPTION
    Deploys a locked-down Azure Storage Account with:
      - Azure Files share (SMB, Entra ID RBAC only)
      - Private Endpoint + Private DNS Zone (no public access)
      - RBAC assignment for the deploying user/group

    The share is accessible from any VNet-connected client (P2S VPN, Bastion,
    or peered VNets) using Entra ID credentials.  No shared keys or SAS tokens.

.PARAMETER NamePrefix
    Base name prefix for all resources (max 10 chars).

.PARAMETER Location
    Azure region for deployment (e.g., eastus, westus2).

.PARAMETER LabBaseName
    Base name of the lab deployment (e.g., "azlab").  Used to auto-detect the
    lab VNet and PE subnet.  If not provided, you must supply -LabVnetId and
    -PeSubnetId manually.

.PARAMETER LabVnetId
    Full resource ID of the lab VNet.  Auto-detected from LabBaseName if not set.

.PARAMETER PeSubnetId
    Full resource ID of the PE subnet in the lab VNet.  Auto-detected from
    LabBaseName if not set.

.PARAMETER ShareQuotaGiB
    Azure Files share quota in GiB (default: 100).

.PARAMETER SubscriptionId
    Target subscription ID.  If not set, uses current az CLI default.

.PARAMETER Destroy
    Remove the artifacts resource group and all resources.

.EXAMPLE
    # Deploy using auto-detection from lab base name
    .\deploy.ps1 -NamePrefix artifacts -Location eastus -LabBaseName azlab

.EXAMPLE
    # Deploy with explicit VNet/subnet IDs
    .\deploy.ps1 -NamePrefix artifacts -Location eastus -LabVnetId "/subscriptions/.../providers/Microsoft.Network/virtualNetworks/azlab-vnet" -PeSubnetId "/subscriptions/.../subnets/snet-pe"

.EXAMPLE
    # Destroy
    .\deploy.ps1 -NamePrefix artifacts -Destroy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$NamePrefix,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [string]$LabBaseName,

    [string]$LabVnetId,

    [string]$PeSubnetId,

    [int]$ShareQuotaGiB = 100,

    [string]$SubscriptionId,

    [switch]$Destroy
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

# Location is required for deploy but not destroy
if (-not $Destroy -and -not $Location) {
    Write-Host "ERROR: -Location is required for deployment." -ForegroundColor Red
    exit 1
}

# =============================================================================
# Helpers
# =============================================================================
function Write-Header { param([string]$Message) Write-Host "`n============================================================" -ForegroundColor Cyan; Write-Host "  $Message" -ForegroundColor Cyan; Write-Host "============================================================" -ForegroundColor Cyan }
function Write-Step   { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Yellow }
function Write-Ok     { param([string]$Message) Write-Host "   [OK] $Message" -ForegroundColor Green }
function Write-Fail   { param([string]$Message) Write-Host "   [FAIL] $Message" -ForegroundColor Red }

# =============================================================================
# 1. Prerequisite Checks
# =============================================================================
Write-Header "Artifacts Storage — Prerequisite Check"

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
    $tokenJson = az account get-access-token 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Token expired" }
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
    Write-Host "   Not logged in. Opening browser..." -ForegroundColor Yellow
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
# 1a. Destroy Mode
# =============================================================================
if ($Destroy) {
    Write-Header "DESTROY MODE — Removing artifacts resources for '$NamePrefix'"

    $rgName = "$NamePrefix-rg-artifacts"
    $exists = az group exists --name $rgName 2>&1
    if ($exists -ne 'true') {
        Write-Host "   Resource group '$rgName' does not exist. Nothing to delete." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "`n   The following resource group will be PERMANENTLY DELETED:" -ForegroundColor Red
    Write-Host "     - $rgName" -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "   Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Host "   Aborted." -ForegroundColor Yellow
        exit 0
    }

    az group delete --name $rgName --yes --no-wait
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to initiate deletion." }
    else { Write-Ok "Deletion initiated for $rgName (running in background)" }
    exit 0
}

# =============================================================================
# 2. Detect Lab VNet & PE Subnet
# =============================================================================
Write-Step "Resolving lab VNet and PE subnet..."

if (-not [string]::IsNullOrWhiteSpace($LabVnetId) -and -not [string]::IsNullOrWhiteSpace($PeSubnetId)) {
    Write-Ok "VNet ID (from parameter): $LabVnetId"
    Write-Ok "PE Subnet ID (from parameter): $PeSubnetId"
} elseif (-not [string]::IsNullOrWhiteSpace($LabBaseName)) {
    $labRgNetwork = "$LabBaseName-rg-network"
    $labVnetName = "$LabBaseName-vnet"

    Write-Host "   Looking up VNet '$labVnetName' in resource group '$labRgNetwork'..." -ForegroundColor Gray
    $LabVnetId = az network vnet show -g $labRgNetwork -n $labVnetName --query id -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LabVnetId)) {
        Write-Fail "Could not find VNet '$labVnetName' in '$labRgNetwork'. Ensure the lab is deployed."
        exit 1
    }
    $LabVnetId = $LabVnetId.Trim()
    Write-Ok "VNet: $LabVnetId"

    $PeSubnetId = az network vnet subnet show -g $labRgNetwork --vnet-name $labVnetName -n snet-pe --query id -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($PeSubnetId)) {
        Write-Fail "Could not find subnet 'snet-pe' in VNet '$labVnetName'. Ensure the lab is deployed with the PE subnet."
        exit 1
    }
    $PeSubnetId = $PeSubnetId.Trim()
    Write-Ok "PE Subnet: $PeSubnetId"
} else {
    Write-Fail "Provide either -LabBaseName (auto-detect) or both -LabVnetId and -PeSubnetId."
    exit 1
}

# =============================================================================
# 3. RBAC — Deployer identity
# =============================================================================
$DeployerObjectId = ''
$PrincipalType = 'User'

Write-Step "RBAC assignment for file share access..."
Write-Host "   Enter a user (UPN) or Entra ID group name to grant file share access." -ForegroundColor White
Write-Host "   This grants Storage File Data SMB Share Contributor on the share." -ForegroundColor Gray
Write-Host "   Leave blank to skip (you can assign RBAC manually later)." -ForegroundColor Gray
$rbacInput = Read-Host "   User UPN or Group name"

if (-not [string]::IsNullOrWhiteSpace($rbacInput)) {
    $rbacInput = $rbacInput.Trim()
    if ($rbacInput -match '@') {
        $userObj = az ad user show --id $rbacInput --query id -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($userObj)) {
            $DeployerObjectId = $userObj.Trim()
            $PrincipalType = 'User'
            Write-Ok "User found — Object ID: $DeployerObjectId"
        } else { Write-Fail "User '$rbacInput' not found. Skipping RBAC." }
    } else {
        $groupObj = az ad group show --group $rbacInput --query id -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($groupObj)) {
            $DeployerObjectId = $groupObj.Trim()
            $PrincipalType = 'Group'
            Write-Ok "Group found — Object ID: $DeployerObjectId"
        } else { Write-Fail "Group '$rbacInput' not found. Skipping RBAC." }
    }
} else {
    Write-Host "   Skipped — assign RBAC manually later." -ForegroundColor Yellow
}

# =============================================================================
# 4. Validate template
# =============================================================================
Write-Step "Validating Bicep template..."
$templateFile = Join-Path $ScriptRoot 'main.bicep'

if (-not (Test-Path $templateFile)) {
    Write-Fail "main.bicep not found at: $templateFile"
    exit 1
}
az bicep build --file $templateFile 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Bicep compilation failed. Run: az bicep build --file main.bicep"
    exit 1
}
Write-Ok "Template compiled successfully"

# =============================================================================
# 5. Deploy
# =============================================================================
$deployParams = @(
    "namePrefix=$NamePrefix"
    "location=$Location"
    "labVnetId=$LabVnetId"
    "peSubnetId=$PeSubnetId"
    "deployerObjectId=$DeployerObjectId"
    "principalType=$PrincipalType"
    "shareQuotaGiB=$ShareQuotaGiB"
)

Write-Header "Deployment Summary"
Write-Host "  Name Prefix     : $NamePrefix" -ForegroundColor White
Write-Host "  Location        : $Location" -ForegroundColor White
Write-Host "  Share Quota     : ${ShareQuotaGiB} GiB" -ForegroundColor White
Write-Host "  Lab VNet        : $LabVnetId" -ForegroundColor White
Write-Host "  PE Subnet       : $PeSubnetId" -ForegroundColor White
Write-Host "  RBAC Principal  : $(if ($DeployerObjectId) { $DeployerObjectId } else { '(none)' })" -ForegroundColor White
Write-Host "  Template        : $templateFile" -ForegroundColor White

# --- Refresh token before deploy ---
Write-Step "Validating Azure CLI session..."
$tokenCheck = az account get-access-token --query "expiresOn" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Session expired. Re-authenticating..." -ForegroundColor Yellow
    az login | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "Login failed."; exit 1 }
    if ($SubscriptionId) { az account set --subscription $SubscriptionId 2>&1 | Out-Null }
} else {
    Write-Ok "Session valid (token expires: $tokenCheck)"
}

Write-Header "Starting Deployment"
$deploymentName = "$NamePrefix-artifacts-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters @deployParams `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Deployment failed. Check Azure portal or run:"
    Write-Host "   az deployment sub show --name $deploymentName --query properties.error" -ForegroundColor Gray
    exit 1
}

# =============================================================================
# 6. Post-Deployment Summary
# =============================================================================
Write-Header "Deployment Complete!"
Write-Host ""

# Retrieve outputs
$outputs = az deployment sub show --name $deploymentName --query "properties.outputs" -o json 2>&1 | ConvertFrom-Json
$stgName     = $outputs.storageAccountName.value
$shareName   = $outputs.fileShareName.value
$rgName      = $outputs.resourceGroupName.value

Write-Host "  Resource Group    : $rgName" -ForegroundColor White
Write-Host "  Storage Account   : $stgName" -ForegroundColor White
Write-Host "  File Share        : $shareName" -ForegroundColor White
Write-Host ""
Write-Host "  Access (requires VPN or VNet connectivity):" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Upload a file:" -ForegroundColor White
Write-Host "    az storage file upload --account-name $stgName --share-name $shareName --source <local-file> --auth-mode login" -ForegroundColor Gray
Write-Host ""
Write-Host "  List files:" -ForegroundColor White
Write-Host "    az storage file list --account-name $stgName --share-name $shareName --auth-mode login -o table" -ForegroundColor Gray
Write-Host ""
Write-Host "  Download a file:" -ForegroundColor White
Write-Host "    az storage file download --account-name $stgName --share-name $shareName --path <filename> --dest <local-path> --auth-mode login" -ForegroundColor Gray
Write-Host ""
Write-Host "  Mount via SMB (from domain-joined or Entra-joined VM on the VNet):" -ForegroundColor White
Write-Host "    net use Z: \\$stgName.file.core.windows.net\$shareName" -ForegroundColor Gray
Write-Host ""
Write-Host "  NOTE: This storage account has NO public access." -ForegroundColor Yellow
Write-Host "  You must be connected via VPN or on a VNet-connected VM." -ForegroundColor Yellow
Write-Host ""

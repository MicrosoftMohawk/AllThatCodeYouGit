<#
.SYNOPSIS
    Deploy Management VM — Standalone post-deployment step for Azure Global Lab.

.DESCRIPTION
    Deploys a pure Entra ID-joined management VM into the existing identity
    resource group created by the main lab deployment (deploy.ps1).

    Run this AFTER deploy.ps1 completes successfully. The management VM needs
    the domain controllers to be online with DNS forwarders configured so it
    can resolve Entra ID endpoints for AAD join.

    The script will:
      1. Deploy the VM (Windows Server 2022, AD subnet, static IP 10.0.1.7)
      2. Wait for Entra ID DNS endpoints to become resolvable
      3. Apply AADLoginForWindows extension (pure Entra ID join)
      4. Install RSAT, Az PowerShell, Azure CLI, SqlServer module
      5. Assign VM Administrator Login RBAC to the deployer (optional)

.PARAMETER BaseName
    Base name prefix used in the main lab deployment.

.PARAMETER Location
    Azure region (must match the main lab deployment).

.PARAMETER AdminPassword
    VM local admin password. If omitted, retrieves from Key Vault.

.PARAMETER WhatIf
    Preview changes without deploying.

.PARAMETER Destroy
    Remove the management VM and its resources.

.EXAMPLE
    # Deploy mgmt VM after lab is running
    .\deploy-mgmt.ps1 -BaseName ts10 -Location westus

.EXAMPLE
    # Preview
    .\deploy-mgmt.ps1 -BaseName ts10 -Location westus -WhatIf

.EXAMPLE
    # Tear down just the mgmt VM
    .\deploy-mgmt.ps1 -BaseName ts10 -Destroy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [string]$AdminPassword,

    [switch]$WhatIf,

    [switch]$Destroy
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

$rgIdentity = "$BaseName-rg-identity"
$vmName = "$BaseName-mgmt"

# =============================================================================
# Destroy mode
# =============================================================================
if ($Destroy) {
    Write-Header "Destroy Management VM: $vmName"

    Write-Step "Checking if VM exists..."
    $vmExists = az vm show --resource-group $rgIdentity --name $vmName --query "name" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Ok "VM '$vmName' not found in $rgIdentity. Nothing to destroy."
        exit 0
    }

    Write-Host "   This will delete:" -ForegroundColor Yellow
    Write-Host "     - VM: $vmName" -ForegroundColor Gray
    Write-Host "     - NIC: $vmName-nic" -ForegroundColor Gray
    Write-Host "     - OS disk" -ForegroundColor Gray
    Write-Host "     - Extensions (AADLoginForWindows, RunCommands)" -ForegroundColor Gray
    $confirm = Read-Host "   Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Host "   Aborted." -ForegroundColor Yellow
        exit 0
    }

    Write-Step "Deleting VM $vmName..."
    az vm delete --resource-group $rgIdentity --name $vmName --yes --force-deletion true 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "VM deleted" } else { Write-Fail "VM deletion failed" }

    # Clean up NIC
    Write-Step "Deleting NIC..."
    az network nic delete --resource-group $rgIdentity --name "$vmName-nic" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "NIC deleted" } else { Write-Host "   NIC not found or already deleted" -ForegroundColor Gray }

    # Clean up OS disk (named after VM by convention)
    Write-Step "Deleting OS disk..."
    $osDisk = az disk list --resource-group $rgIdentity --query "[?starts_with(name, '$vmName')].name" -o tsv 2>&1
    if ($osDisk -and $LASTEXITCODE -eq 0) {
        foreach ($disk in $osDisk -split "`n") {
            $disk = $disk.Trim()
            if ($disk) {
                az disk delete --resource-group $rgIdentity --name $disk --yes 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Ok "Disk '$disk' deleted" }
            }
        }
    } else {
        Write-Host "   No OS disks found" -ForegroundColor Gray
    }

    Write-Ok "Management VM cleanup complete."
    exit 0
}

# =============================================================================
# Deploy mode — validate parameters
# =============================================================================
if (-not $Location) {
    Write-Fail "-Location is required for deployment."
    exit 1
}

Write-Header "Deploy Management VM: $vmName"

# --- Check Azure CLI session --------------------------------------------------
Write-Step "Validating Azure CLI session..."
$tokenCheck = az account get-access-token --query "expiresOn" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Session expired. Re-authenticating..." -ForegroundColor Yellow
    az login | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "Login failed."; exit 1 }
}
$account = az account show 2>&1 | ConvertFrom-Json
Write-Ok "Logged in as $($account.user.name) (subscription: $($account.name))"

# --- Verify the identity RG exists (main deployment must have completed) ------
Write-Step "Verifying main lab deployment exists..."
$rgCheck = az group show --name $rgIdentity --query "name" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Resource group '$rgIdentity' not found. Run deploy.ps1 first."
    exit 1
}
Write-Ok "Resource group $rgIdentity exists"

# --- Retrieve admin password from Key Vault if not provided -------------------
if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    Write-Step "Retrieving admin password from Key Vault..."
    $kvName = az keyvault list --resource-group $rgIdentity --query "[0].name" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvName)) {
        Write-Fail "Could not find Key Vault in $rgIdentity. Provide -AdminPassword manually."
        exit 1
    }
    $AdminPassword = az keyvault secret show --vault-name $kvName --name "vm-admin-password" --query "value" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AdminPassword)) {
        Write-Fail "Could not retrieve password from Key Vault '$kvName'. Provide -AdminPassword manually."
        exit 1
    }
    Write-Ok "Admin password retrieved from Key Vault '$kvName'"
}

# --- Resolve deployer object ID for RBAC -------------------------------------
Write-Step "Resolving deployer identity for RBAC..."
$deployerObjectId = ''
try {
    $deployerObjectId = az ad signed-in-user show --query "id" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { $deployerObjectId = '' }
} catch {
    $deployerObjectId = ''
}
if ($deployerObjectId) {
    Write-Ok "Deployer: $deployerObjectId (will get VM Admin Login RBAC)"
} else {
    Write-Host "   Could not resolve deployer identity. RBAC will be skipped." -ForegroundColor Yellow
    Write-Host "   You can assign manually: az role assignment create ..." -ForegroundColor Gray
}

# --- Deploy -------------------------------------------------------------------
$templateFile = Join-Path $ScriptRoot 'mgmt.bicep'
$deploymentName = "$BaseName-mgmt-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$deployParams = @(
    "baseName=$BaseName"
    "location=$Location"
    "adminPassword=$AdminPassword"
    "deployerObjectId=$deployerObjectId"
)

Write-Header "Deployment Summary"
Write-Host "  Base Name     : $BaseName" -ForegroundColor White
Write-Host "  Location      : $Location" -ForegroundColor White
Write-Host "  Resource Group: $rgIdentity" -ForegroundColor White
Write-Host "  VM Name       : $vmName" -ForegroundColor White
Write-Host "  Template      : $templateFile" -ForegroundColor White
Write-Host ""

if ($WhatIf) {
    Write-Header "What-If Preview"
    az deployment group what-if `
        --resource-group $rgIdentity `
        --template-file $templateFile `
        --parameters @deployParams
    Write-Host "`nWhat-If complete. No resources were modified." -ForegroundColor Cyan
    exit 0
}

Write-Header "Deploying Management VM"
az deployment group create `
    --name $deploymentName `
    --resource-group $rgIdentity `
    --template-file $templateFile `
    --parameters @deployParams `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Management VM deployment failed."
    Write-Host "   Check: az deployment group show --resource-group $rgIdentity --name $deploymentName --query properties.error" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   The main lab deployment is unaffected. Fix and re-run this script." -ForegroundColor Yellow
    exit 1
}

# --- Set timezone (match other lab VMs if not UTC) ----------------------------
# Quick best-effort timezone set — skip if it fails
$tz = (Get-TimeZone).Id
if ($tz -ne 'UTC') {
    Write-Step "Setting VM timezone to $tz..."
    az vm run-command invoke `
        --resource-group $rgIdentity `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts "Set-TimeZone -Id '$tz'" `
        --query "value[0].message" -o tsv 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "Timezone set to $tz" }
    else { Write-Host "   WARNING: Timezone set failed (non-fatal)" -ForegroundColor Yellow }
}

# =============================================================================
# Post-Deployment Summary
# =============================================================================
Write-Header "Management VM Deployed Successfully!"
Write-Host ""
Write-Host "  VM Name       : $vmName" -ForegroundColor White
Write-Host "  Resource Group: $rgIdentity" -ForegroundColor White
Write-Host "  IP Address    : 10.0.1.7 (static)" -ForegroundColor White
Write-Host "  Join Type     : Pure Entra ID join (not domain-joined)" -ForegroundColor White
Write-Host ""
Write-Host "  Installed:" -ForegroundColor Cyan
Write-Host "    - AADLoginForWindows (Entra ID login via Bastion)" -ForegroundColor Gray
Write-Host "    - RSAT (AD Users & Computers, DNS, Group Policy)" -ForegroundColor Gray
Write-Host "    - Az PowerShell, Azure CLI, SqlServer module" -ForegroundColor Gray
Write-Host ""
Write-Host "  To connect:" -ForegroundColor Cyan
Write-Host "    1. Portal > Bastion > Connect to $vmName" -ForegroundColor Gray
Write-Host "    2. Sign in with your Entra ID credentials" -ForegroundColor Gray
Write-Host ""
Write-Host "  To manage AD (from mgmt VM):" -ForegroundColor Cyan
Write-Host "    runas /netonly /user:<domain>\lab-admin mmc.exe" -ForegroundColor Gray
Write-Host "    (lab-admin has delegated control over Lab OUs)" -ForegroundColor Gray
Write-Host ""

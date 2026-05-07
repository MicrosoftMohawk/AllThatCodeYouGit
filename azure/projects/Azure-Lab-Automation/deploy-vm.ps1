<#
.SYNOPSIS
    Deploy a single Windows Server VM into the existing Azure Global Lab.

.DESCRIPTION
    Deploys a standalone VM into one of the lab subnets (snet-ad, snet-main,
    snet-site1, snet-site2) with optional domain join. Reuses the existing
    lab infrastructure (VNet, Key Vault, AD) deployed by deploy.ps1.

    The script will:
      1. Validate the lab infrastructure exists
      2. Retrieve the admin password from Key Vault (or accept -AdminPassword)
      3. Prompt for OS image selection (Server 2022 or 2025)
      4. Prompt for target subnet
      5. Deploy the VM using the existing vm.bicep module
      6. Optionally domain-join the VM

.PARAMETER BaseName
    Base name prefix used in the main lab deployment.

.PARAMETER VmName
    Name for the new VM (max 15 characters for Windows computer name).

.PARAMETER Location
    Azure region (must match the main lab deployment).

.PARAMETER Subnet
    Target subnet: ad, main, site1, or site2. If omitted, an interactive prompt is shown.

.PARAMETER OsImage
    OS image version: 2022 or 2025. If omitted, an interactive prompt is shown.

.PARAMETER VmSize
    VM size SKU. Default: Standard_D2s_v5.

.PARAMETER AdminPassword
    VM local admin password. If omitted, retrieves from Key Vault.

.PARAMETER SkipDomainJoin
    Do not domain-join the VM (deploy as workgroup server).

.PARAMETER OuPath
    OU path for the computer object. Default: places in Lab Servers\App Servers.

.PARAMETER StaticIp
    Optional static private IP address for the VM NIC.

.PARAMETER DataDiskCount
    Number of 128 GB data disks to attach (0-4). Default: 0.

.PARAMETER WhatIf
    Preview changes without deploying.

.PARAMETER Destroy
    Delete the specified VM and its resources.

.EXAMPLE
    # Deploy a Server 2025 VM into snet-main, domain-joined
    .\deploy-vm.ps1 -BaseName gisa -VmName gisa-test01 -Location eastus -Subnet main -OsImage 2025

.EXAMPLE
    # Deploy a workgroup VM (no domain join)
    .\deploy-vm.ps1 -BaseName gisa -VmName gisa-wg01 -Location eastus -Subnet site1 -SkipDomainJoin

.EXAMPLE
    # Interactive mode (prompts for subnet and OS)
    .\deploy-vm.ps1 -BaseName gisa -VmName gisa-app01 -Location eastus

.EXAMPLE
    # Destroy a VM
    .\deploy-vm.ps1 -BaseName gisa -VmName gisa-test01 -Destroy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 15)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [ValidateSet('ad', 'main', 'site1', 'site2')]
    [string]$Subnet,

    [ValidateSet('2022', '2025')]
    [string]$OsImage,

    [string]$VmSize = 'Standard_D2s_v5',

    [string]$AdminPassword,

    [switch]$SkipDomainJoin,

    [string]$OuPath,

    [string]$StaticIp,

    [ValidateRange(0, 4)]
    [int]$DataDiskCount = 0,

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

# Resource group naming convention from main deployment
$rgIdentity = "$BaseName-rg-identity"
$rgNetwork  = "$BaseName-rg-network"
$vnetName   = "$BaseName-vnet"

# Subnet name mapping
$subnetMap = @{
    'ad'    = @{ Name = 'snet-ad';    Display = 'snet-ad (10.0.1.0/24) — Identity' }
    'main'  = @{ Name = 'snet-main';  Display = 'snet-main (10.0.20.0/24) — Main Site / HQ' }
    'site1' = @{ Name = 'snet-site1'; Display = 'snet-site1 (10.0.30.0/24) — Remote Site 1' }
    'site2' = @{ Name = 'snet-site2'; Display = 'snet-site2 (10.0.40.0/24) — Remote Site 2' }
}

# Image SKU mapping
$imageSkuMap = @{
    '2022' = @{ Sku = '2022-datacenter-g2'; Display = 'Windows Server 2022 Datacenter (Gen2)' }
    '2025' = @{ Sku = '2025-datacenter-g2'; Display = 'Windows Server 2025 Datacenter (Gen2)' }
}

# =============================================================================
# Destroy mode
# =============================================================================
if ($Destroy) {
    Write-Header "Destroy VM: $VmName"

    # Find which RG the VM is in
    $vmRg = $null
    foreach ($rg in @($rgIdentity, "$BaseName-rg-main", "$BaseName-rg-site1", "$BaseName-rg-site2")) {
        $check = az vm show --resource-group $rg --name $VmName --query "name" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0) { $vmRg = $rg; break }
    }

    if (-not $vmRg) {
        Write-Ok "VM '$VmName' not found in any lab resource group. Nothing to destroy."
        exit 0
    }

    Write-Host "   Found VM '$VmName' in resource group: $vmRg" -ForegroundColor White
    Write-Host "   This will delete:" -ForegroundColor Yellow
    Write-Host "     - VM: $VmName" -ForegroundColor Gray
    Write-Host "     - NIC: $VmName-nic" -ForegroundColor Gray
    Write-Host "     - OS disk" -ForegroundColor Gray
    $confirm = Read-Host "   Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Host "   Aborted." -ForegroundColor Yellow
        exit 0
    }

    Write-Step "Deleting VM $VmName..."
    az vm delete --resource-group $vmRg --name $VmName --yes --force-deletion true 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "VM deleted" } else { Write-Fail "VM deletion failed" }

    Write-Step "Deleting NIC..."
    az network nic delete --resource-group $vmRg --name "$VmName-nic" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "NIC deleted" } else { Write-Host "   NIC not found or already deleted" -ForegroundColor Gray }

    Write-Step "Deleting OS disk..."
    $osDisk = az disk list --resource-group $vmRg --query "[?starts_with(name, '$VmName')].name" -o tsv 2>&1
    if ($osDisk -and $LASTEXITCODE -eq 0) {
        foreach ($disk in $osDisk -split "`n") {
            $disk = $disk.Trim()
            if ($disk) {
                az disk delete --resource-group $vmRg --name $disk --yes 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Ok "Disk '$disk' deleted" }
            }
        }
    } else {
        Write-Host "   No OS disks found" -ForegroundColor Gray
    }

    Write-Ok "VM cleanup complete."
    exit 0
}

# =============================================================================
# Deploy mode — validate parameters
# =============================================================================
if (-not $Location) {
    Write-Fail "-Location is required for deployment."
    exit 1
}

Write-Header "Deploy Single VM: $VmName"

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

# --- Verify the lab infrastructure exists -------------------------------------
Write-Step "Verifying lab infrastructure..."
$rgCheck = az group show --name $rgIdentity --query "name" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Resource group '$rgIdentity' not found. Run deploy.ps1 first."
    exit 1
}
Write-Ok "Lab infrastructure found ($rgIdentity)"

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
        Write-Fail "Could not retrieve password from Key Vault. Ensure VPN + DNS is configured, or provide -AdminPassword."
        exit 1
    }
    Write-Ok "Admin password retrieved from Key Vault"
} else {
    Write-Ok "Admin password provided via parameter"
}

# --- OS Image Selection -------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($OsImage)) {
    $SelectedImageSku = $imageSkuMap[$OsImage].Sku
    Write-Ok "OS Image (from parameter): $($imageSkuMap[$OsImage].Display)"
} else {
    Write-Step "Select OS image..."
    Write-Host "   [1] $($imageSkuMap['2022'].Display)" -ForegroundColor White
    Write-Host "   [2] $($imageSkuMap['2025'].Display)" -ForegroundColor White
    $osChoice = Read-Host "`n   Enter choice (1-2, default: 1)"
    if ([string]::IsNullOrWhiteSpace($osChoice)) { $osChoice = '1' }

    switch ($osChoice) {
        '1' { $SelectedImageSku = $imageSkuMap['2022'].Sku }
        '2' { $SelectedImageSku = $imageSkuMap['2025'].Sku }
        default {
            Write-Fail "Invalid choice. Defaulting to Windows Server 2022 Datacenter."
            $SelectedImageSku = $imageSkuMap['2022'].Sku
        }
    }
}
Write-Ok "OS Image: $SelectedImageSku"

# --- Subnet Selection ---------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($Subnet)) {
    $SelectedSubnet = $Subnet
    Write-Ok "Subnet (from parameter): $($subnetMap[$Subnet].Display)"
} else {
    Write-Step "Select target subnet..."
    $keys = @('ad', 'main', 'site1', 'site2')
    for ($i = 0; $i -lt $keys.Count; $i++) {
        Write-Host "   [$($i+1)] $($subnetMap[$keys[$i]].Display)" -ForegroundColor White
    }
    $snetChoice = Read-Host "`n   Enter choice (1-4, default: 2 — snet-main)"
    if ([string]::IsNullOrWhiteSpace($snetChoice)) { $snetChoice = '2' }

    switch ($snetChoice) {
        '1' { $SelectedSubnet = 'ad' }
        '2' { $SelectedSubnet = 'main' }
        '3' { $SelectedSubnet = 'site1' }
        '4' { $SelectedSubnet = 'site2' }
        default {
            Write-Fail "Invalid choice. Defaulting to snet-main."
            $SelectedSubnet = 'main'
        }
    }
}
Write-Ok "Subnet: $($subnetMap[$SelectedSubnet].Display)"

# --- Resolve subnet resource ID -----------------------------------------------
$subnetName = $subnetMap[$SelectedSubnet].Name
$subnetId = az network vnet subnet show --resource-group $rgNetwork --vnet-name $vnetName --name $subnetName --query "id" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Could not resolve subnet '$subnetName' in VNet '$vnetName'. Verify lab deployment."
    exit 1
}
Write-Ok "Subnet ID resolved"

# --- Determine resource group for the VM --------------------------------------
$vmRg = switch ($SelectedSubnet) {
    'ad'    { $rgIdentity }
    'main'  { "$BaseName-rg-main" }
    'site1' { "$BaseName-rg-site1" }
    'site2' { "$BaseName-rg-site2" }
}

# Verify the target RG exists
$rgExists = az group show --name $vmRg --query "name" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    # If deploying to main/site1/site2 and that RG doesn't exist, it may not have been deployed yet
    Write-Fail "Resource group '$vmRg' not found. Ensure the lab is deployed to at least the tier that creates this subnet."
    exit 1
}

# --- Detect domain name for domain join ---------------------------------------
$DomainJoin = -not $SkipDomainJoin
$DomainName = $null
if ($DomainJoin) {
    Write-Step "Detecting AD domain name from DC01..."
    $dc01Name = "$BaseName-dc01"
    $DomainName = az vm run-command invoke --resource-group $rgIdentity --name $dc01Name `
        --command-id RunPowerShellScript `
        --scripts "(Get-ADDomain).DnsRoot" `
        --query "value[0].message" -o tsv 2>&1
    # Parse the output — RunCommand returns stdout after [stdout]
    if ($DomainName -match '\[stdout\]\s*(.+)') {
        $DomainName = $Matches[1].Trim()
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($DomainName) -or $DomainName -match 'ERROR|exception') {
        Write-Host "   Could not auto-detect domain name." -ForegroundColor Yellow
        $DomainName = Read-Host "   Enter the AD domain name (e.g., azlab.local)"
        if ([string]::IsNullOrWhiteSpace($DomainName)) {
            Write-Fail "Domain name is required for domain join. Use -SkipDomainJoin to skip."
            exit 1
        }
    }
    Write-Ok "Domain: $DomainName"

    # Set default OU path if not provided
    if ([string]::IsNullOrWhiteSpace($OuPath)) {
        $domainDn = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','
        $OuPath = "OU=App Servers,OU=Lab Servers,$domainDn"
    }
}

# =============================================================================
# Deployment Summary
# =============================================================================
Write-Header "Deployment Summary"
Write-Host "  VM Name         : $VmName" -ForegroundColor White
Write-Host "  Resource Group  : $vmRg" -ForegroundColor White
Write-Host "  Location        : $Location" -ForegroundColor White
Write-Host "  VM Size         : $VmSize" -ForegroundColor White
Write-Host "  OS Image        : $SelectedImageSku" -ForegroundColor White
Write-Host "  Subnet          : $($subnetMap[$SelectedSubnet].Display)" -ForegroundColor White
Write-Host "  Static IP       : $(if ($StaticIp) { $StaticIp } else { '(dynamic)' })" -ForegroundColor White
Write-Host "  Data Disks      : $DataDiskCount" -ForegroundColor White
Write-Host "  Domain Join     : $(if ($DomainJoin) { "$DomainName (OU: $OuPath)" } else { 'No (workgroup)' })" -ForegroundColor White

if ($WhatIf) {
    Write-Host "`n  [WHAT-IF] No changes will be made." -ForegroundColor Cyan
    exit 0
}

Write-Host ""
$confirm = Read-Host "  Proceed with deployment? (Y/n)"
if ($confirm -match '^[Nn]') {
    Write-Host "  Aborted." -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# Deploy VM using Bicep module
# =============================================================================
Write-Step "Deploying VM '$VmName'..."

$templateFile = Join-Path $ScriptRoot 'modules' 'compute' 'vm.bicep'
$deploymentName = "vm-$VmName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$deployParams = @(
    "vmName=$VmName"
    "location=$Location"
    "vmSize=$VmSize"
    "subnetId=$subnetId"
    "adminUsername=labadmin"
    "adminPassword=$AdminPassword"
    "imageSku=$SelectedImageSku"
    "dataDiskCount=$DataDiskCount"
)

if (-not [string]::IsNullOrWhiteSpace($StaticIp)) {
    $deployParams += "privateIpAddress=$StaticIp"
}

$tagsJson = "{`"project`":`"azure-lab`",`"env`":`"lab`",`"baseName`":`"$BaseName`"}"
$deployParams += "tags=$tagsJson"

Write-Host "   Resource Group : $vmRg" -ForegroundColor Gray
Write-Host "   Template       : $templateFile" -ForegroundColor Gray

az deployment group create `
    --name $deploymentName `
    --resource-group $vmRg `
    --template-file $templateFile `
    --parameters @deployParams `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Fail "VM deployment failed."
    exit 1
}
Write-Ok "VM '$VmName' deployed successfully"

# =============================================================================
# Domain Join (if enabled)
# =============================================================================
if ($DomainJoin) {
    Write-Step "Domain-joining '$VmName' to $DomainName..."

    $domainJoinTemplate = Join-Path $ScriptRoot 'modules' 'identity' 'domainJoin.bicep'
    $djDeploymentName = "dj-$VmName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    $djParams = @(
        "vmName=$VmName"
        "location=$Location"
        "domainName=$DomainName"
        "domainJoinUser=svc-domjoin@$DomainName"
        "domainJoinPassword=$AdminPassword"
        "ouPath=$OuPath"
    )

    az deployment group create `
        --name $djDeploymentName `
        --resource-group $vmRg `
        --template-file $domainJoinTemplate `
        --parameters @djParams `
        --verbose

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Domain join failed. The VM is deployed but not joined to the domain."
        Write-Host "   You can retry manually or join via the VM." -ForegroundColor Yellow
    } else {
        Write-Ok "VM '$VmName' joined to $DomainName"
    }
}

# =============================================================================
# Done
# =============================================================================
Write-Header "Deployment Complete"
Write-Host "  VM Name    : $VmName" -ForegroundColor White
Write-Host "  RG         : $vmRg" -ForegroundColor White
Write-Host "  OS         : $SelectedImageSku" -ForegroundColor White
Write-Host "  Subnet     : $($subnetMap[$SelectedSubnet].Display)" -ForegroundColor White
if ($DomainJoin) {
    Write-Host "  Domain     : $DomainName" -ForegroundColor White
}
Write-Host ""
Write-Host "  Connect via Bastion:" -ForegroundColor Gray
Write-Host "    Portal > $BaseName-bastion > Connect to VM > $VmName" -ForegroundColor Gray
Write-Host "  Connect via VPN (RDP):" -ForegroundColor Gray
Write-Host "    mstsc /v:<private-ip>" -ForegroundColor Gray
Write-Host ""

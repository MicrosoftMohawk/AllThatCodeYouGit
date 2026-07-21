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
    VM size SKU. Default: Standard_B2as_v2.

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

    [string]$VmSize = 'Standard_B2as_v2',

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

    # Find the vault name. Separate stdout/stderr so a warning on stderr
    # doesn't end up in the variable we plan to use.
    $kvErr = [System.IO.Path]::GetTempFileName()
    try {
        $kvName = (az keyvault list --resource-group $rgIdentity --query "[0].name" -o tsv 2>$kvErr) | Out-String
        $kvName = $kvName.Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvName)) {
            $errText = (Get-Content $kvErr -Raw -ErrorAction SilentlyContinue)
            Write-Fail "Could not find Key Vault in $rgIdentity. Provide -AdminPassword manually."
            if ($errText) { Write-Host "   CLI error: $errText" -ForegroundColor Gray }
            exit 1
        }
    }
    finally { Remove-Item $kvErr -Force -ErrorAction SilentlyContinue }

    Write-Host "   Vault: $kvName" -ForegroundColor Gray

    # Fetch the secret. Route stderr to a temp file so we can surface the real
    # error message (403, DNS/network, secret-not-found, disabled, etc.)
    # instead of a generic failure.
    $secErr = [System.IO.Path]::GetTempFileName()
    try {
        $AdminPassword = (az keyvault secret show --vault-name $kvName --name "vm-admin-password" --query "value" -o tsv 2>$secErr) | Out-String
        $AdminPassword = $AdminPassword.TrimEnd("`r", "`n")
        $secExit = $LASTEXITCODE
        $secErrText = (Get-Content $secErr -Raw -ErrorAction SilentlyContinue)
    }
    finally { Remove-Item $secErr -Force -ErrorAction SilentlyContinue }

    if ($secExit -ne 0 -or [string]::IsNullOrWhiteSpace($AdminPassword)) {
        Write-Fail "Could not retrieve secret 'vm-admin-password' from Key Vault '$kvName'."
        if ($secErrText) {
            Write-Host ""
            Write-Host "   --- Azure CLI error ---" -ForegroundColor Yellow
            Write-Host $secErrText.Trim() -ForegroundColor Gray
            Write-Host "   -----------------------" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "   Common causes:" -ForegroundColor Yellow
        Write-Host "     * Missing RBAC role. You need 'Key Vault Secrets User' (or higher)" -ForegroundColor Gray
        Write-Host "       on vault '$kvName' for principal:" -ForegroundColor Gray
        $upn = az account show --query "user.name" -o tsv 2>$null
        Write-Host "         $upn" -ForegroundColor Gray
        Write-Host "       Grant with:" -ForegroundColor Gray
        Write-Host "         az role assignment create --assignee $upn ``" -ForegroundColor DarkGray
        Write-Host "           --role 'Key Vault Secrets User' ``" -ForegroundColor DarkGray
        Write-Host "           --scope `$(az keyvault show -n $kvName --query id -o tsv)" -ForegroundColor DarkGray
        Write-Host "     * KV firewall blocks your VPN client IP. Test data-plane reach:" -ForegroundColor Gray
        Write-Host "         nslookup $kvName.vault.azure.net" -ForegroundColor DarkGray
        Write-Host "         (should resolve to a private 10.x address)" -ForegroundColor DarkGray
        Write-Host "     * Secret doesn't exist / was purged / soft-deleted. Verify:" -ForegroundColor Gray
        Write-Host "         az keyvault secret list --vault-name $kvName -o table" -ForegroundColor DarkGray
        Write-Host "     * Or pass the password explicitly: -AdminPassword '<value>'" -ForegroundColor Gray
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
    $osChoice = Read-Host "`n   Enter choice (1-2, default: 2)"
    if ([string]::IsNullOrWhiteSpace($osChoice)) { $osChoice = '2' }

    switch ($osChoice) {
        '1' { $SelectedImageSku = $imageSkuMap['2022'].Sku }
        '2' { $SelectedImageSku = $imageSkuMap['2025'].Sku }
        default {
            Write-Fail "Invalid choice. Defaulting to Windows Server 2025 Datacenter."
            $SelectedImageSku = $imageSkuMap['2025'].Sku
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

# Build an ARM parameters file so we don't have to fight PowerShell/cmd quoting
# rules for inline JSON values (e.g. the tags object) on the az CLI command line.
$paramValues = [ordered]@{
    vmName        = @{ value = $VmName }
    location      = @{ value = $Location }
    vmSize        = @{ value = $VmSize }
    subnetId      = @{ value = $subnetId }
    adminUsername = @{ value = 'labadmin' }
    adminPassword = @{ value = $AdminPassword }
    imageSku      = @{ value = $SelectedImageSku }
    dataDiskCount = @{ value = $DataDiskCount }
    tags          = @{ value = @{
            project  = 'azure-lab'
            env      = 'lab'
            baseName = $BaseName
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($StaticIp)) {
    $paramValues['privateIpAddress'] = @{ value = $StaticIp }
}

$paramFileObj = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = $paramValues
}

$vmParamFile = Join-Path ([System.IO.Path]::GetTempPath()) "vm-$VmName-$([Guid]::NewGuid().ToString('N')).parameters.json"
$paramFileObj | ConvertTo-Json -Depth 10 | Set-Content -Path $vmParamFile -Encoding UTF8

Write-Host "   Resource Group : $vmRg" -ForegroundColor Gray
Write-Host "   Template       : $templateFile" -ForegroundColor Gray
Write-Host "   Parameters     : $vmParamFile" -ForegroundColor Gray

# Precompile Bicep -> ARM JSON. This avoids a known `az deployment group create`
# bug ("The content for this response was already consumed") that surfaces
# during the CLI's internal Bicep compilation step.
$compiledTemplate = Join-Path ([System.IO.Path]::GetTempPath()) "vm-$VmName-$([Guid]::NewGuid().ToString('N')).json"
Write-Host "   Compiling Bicep to ARM JSON..." -ForegroundColor Gray
az bicep build --file $templateFile --outfile $compiledTemplate 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $compiledTemplate)) {
    Write-Fail "Bicep compilation failed."
    exit 1
}

$vmDeployExit = 1
try {
    az deployment group create `
        --name $deploymentName `
        --resource-group $vmRg `
        --template-file $compiledTemplate `
        --parameters "@$vmParamFile" `
        --verbose
    $vmDeployExit = $LASTEXITCODE
}
finally {
    if ($vmDeployExit -eq 0) {
        if (Test-Path $vmParamFile)     { Remove-Item $vmParamFile     -Force -ErrorAction SilentlyContinue }
        if (Test-Path $compiledTemplate) { Remove-Item $compiledTemplate -Force -ErrorAction SilentlyContinue }
    }
    else {
        # Keep the temp files around so the user can inspect / re-run manually.
        Write-Host ""
        Write-Host "   Parameters file kept for troubleshooting:" -ForegroundColor Yellow
        Write-Host "     $vmParamFile" -ForegroundColor Gray
        Write-Host "   Compiled ARM template kept for troubleshooting:" -ForegroundColor Yellow
        Write-Host "     $compiledTemplate" -ForegroundColor Gray
        Write-Host "   You can re-run the deployment manually with:" -ForegroundColor Yellow
        Write-Host "     az deployment group create ``" -ForegroundColor DarkGray
        Write-Host "       --name $deploymentName ``" -ForegroundColor DarkGray
        Write-Host "       --resource-group $vmRg ``" -ForegroundColor DarkGray
        Write-Host "       --template-file `"$compiledTemplate`" ``" -ForegroundColor DarkGray
        Write-Host "       --parameters `"@$vmParamFile`" --debug" -ForegroundColor DarkGray
    }
}

if ($vmDeployExit -ne 0) {
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

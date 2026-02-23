<#
.SYNOPSIS
    Azure Global Lab — Deployment Wrapper Script
    Validates prerequisites and deploys the Bicep templates to Azure.

.DESCRIPTION
    This script checks for required tools (Azure CLI, Bicep CLI), validates the
    login session, and executes the Bicep deployment at the subscription scope.

    The deployment is tiered:
      Tier 1: Core networking, AD Domain Controllers, Azure Bastion, Cloud Witness
      Tier 2: + SQL Server VMs (5 total, including AOAG pair at Site 2 with ILB)
      Tier 3: + Application VMs (CAS + 3 child primaries)

.PARAMETER Location
    Azure region for deployment (e.g., eastus, westus2, centralus).

.PARAMETER BaseName
    Base name prefix for all resources. Max 10 characters.

.PARAMETER DeploymentTier
    Which tier to deploy: 1, 2, or 3 (default: 3 = full lab).

.PARAMETER WhatIf
    Preview changes without deploying (Azure What-If).

.PARAMETER Destroy
    Remove all resource groups and resources deployed with the specified -BaseName.

.PARAMETER SubscriptionId
    Target subscription ID. If not set, uses current az CLI default.

.EXAMPLE
    # Deploy full lab (all 3 tiers) to East US
    .\.deploy.ps1 -Location eastus -BaseName azlab -DeploymentTier 3

.EXAMPLE
    # Deploy only core networking and AD (Tier 1)
    .\deploy.ps1 -Location eastus -BaseName azlab -DeploymentTier 1

.EXAMPLE
    # Preview what would be deployed (What-If)
    .\deploy.ps1 -Location eastus -BaseName azlab -WhatIf

.EXAMPLE
    # Deploy to a specific subscription
    .\deploy.ps1 -Location eastus -BaseName azlab -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    # Destroy all resources for a specific lab
    .\deploy.ps1 -BaseName azlab -Location eastus -Destroy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [ValidateSet(1, 2, 3)]
    [int]$DeploymentTier = 3,

    [string]$SubscriptionId,

    [switch]$WhatIf,

    [switch]$Destroy
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

# Location is required for deploy/what-if but not for destroy
if (-not $Destroy -and -not $Location) {
    Write-Host "ERROR: -Location is required for deployment. Example: -Location eastus" -ForegroundColor Red
    exit 1
}

# =============================================================================
# Colours & helpers
# =============================================================================
function Write-Header { param([string]$Message) Write-Host "`n============================================================" -ForegroundColor Cyan; Write-Host "  $Message" -ForegroundColor Cyan; Write-Host "============================================================" -ForegroundColor Cyan }
function Write-Step   { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Yellow }
function Write-Ok     { param([string]$Message) Write-Host "   [OK] $Message" -ForegroundColor Green }
function Write-Fail   { param([string]$Message) Write-Host "   [FAIL] $Message" -ForegroundColor Red }

# =============================================================================
# 1. Prerequisite Checks
# =============================================================================
Write-Header "Azure Global Lab — Prerequisite Check"

# --- Azure CLI ----------------------------------------------------------------
Write-Step "Checking Azure CLI..."
try {
    $azVersionOutput = az version 2>&1 | ConvertFrom-Json
    $azCliVersion = $azVersionOutput.'azure-cli'
    if ([version]$azCliVersion -lt [version]'2.20.0') {
        Write-Fail "Azure CLI version $azCliVersion is too old. Minimum required: 2.20.0"
        Write-Host "   Update: https://learn.microsoft.com/cli/azure/install-azure-cli" -ForegroundColor Gray
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
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to install Bicep CLI. Run manually: az bicep install"
        exit 1
    }
    Write-Ok "Bicep CLI installed"
}

# --- Login session ------------------------------------------------------------
Write-Step "Checking Azure login session..."
try {
    $account = az account show 2>&1 | ConvertFrom-Json
    if (-not $account) { throw "Not logged in" }
    Write-Ok "Logged in as $($account.user.name) (tenant: $($account.tenantId))"
    Write-Host ""
    Write-Host "   [1] Continue with this account" -ForegroundColor White
    Write-Host "   [2] Log in with a different account" -ForegroundColor White
    $choice = Read-Host "   Select (default: 1)"
    if ($choice -eq '2') {
        Write-Host "   Opening browser login..." -ForegroundColor Yellow
        az login | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Login failed. Run 'az login' manually."
            exit 1
        }
        $account = az account show 2>&1 | ConvertFrom-Json
        Write-Ok "Now logged in as $($account.user.name) (tenant: $($account.tenantId))"
    }
} catch {
    Write-Host "   Not logged in. Opening browser login..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Login failed. Run 'az login' manually."
        exit 1
    }
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Ok "Logged in as $($account.user.name)"
}

# --- Subscription selection ---------------------------------------------------
if ($SubscriptionId) {
    Write-Step "Setting subscription to $SubscriptionId..."
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to set subscription. Verify with: az account list --output table"
        exit 1
    }
    Write-Ok "Subscription set"
} else {
    Write-Step "Using current default subscription..."
    $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
    Write-Ok "$($currentSub.name) ($($currentSub.id))"
    Write-Host "   Tip: To list all subscriptions: az account list --output table" -ForegroundColor Gray
    Write-Host "   Tip: To switch: az account set --subscription '<name-or-id>'" -ForegroundColor Gray
}

# --- Key Vault Administrator RBAC ---------------------------------------------
Write-Step "Key Vault Administrator RBAC assignment..."
Write-Host "   Enter a user (UPN) or Entra ID group name to grant Key Vault Administrator." -ForegroundColor White
Write-Host "   Examples: john@contoso.com, SG-KeyVaultAdmins" -ForegroundColor Gray
Write-Host "   Leave blank to skip (you can assign manually later)." -ForegroundColor Gray
$kvAdminInput = Read-Host "   User UPN or Group name"
$DeployerObjectId = ''
$KvPrincipalType = 'User'

if (-not [string]::IsNullOrWhiteSpace($kvAdminInput)) {
    $kvAdminInput = $kvAdminInput.Trim()
    # Try as user first (contains @), then as group
    if ($kvAdminInput -match '@') {
        Write-Host "   Looking up user: $kvAdminInput" -ForegroundColor Gray
        $userObj = az ad user show --id $kvAdminInput --query id -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($userObj)) {
            $DeployerObjectId = $userObj.Trim()
            $KvPrincipalType = 'User'
            Write-Ok "User found — Object ID: $DeployerObjectId"
        } else {
            Write-Fail "User '$kvAdminInput' not found in Entra ID. Skipping KV RBAC."
        }
    } else {
        Write-Host "   Looking up group: $kvAdminInput" -ForegroundColor Gray
        $groupObj = az ad group show --group $kvAdminInput --query id -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($groupObj)) {
            $DeployerObjectId = $groupObj.Trim()
            $KvPrincipalType = 'Group'
            Write-Ok "Group found — Object ID: $DeployerObjectId"
        } else {
            Write-Fail "Group '$kvAdminInput' not found in Entra ID. Skipping KV RBAC."
        }
    }
} else {
    Write-Host "   Skipped — no Key Vault Administrator will be assigned." -ForegroundColor Yellow
}

# =============================================================================
# 1b. Destroy Mode — Remove all resources for this BaseName
# =============================================================================
if ($Destroy) {
    Write-Header "DESTROY MODE — Removing all resources for '$BaseName'"

    $rgNames = @(
        "$BaseName-rg-network"
        "$BaseName-rg-identity"
        "$BaseName-rg-main"
        "$BaseName-rg-site1"
        "$BaseName-rg-site2"
    )

    # Check which resource groups actually exist
    $existingRgs = @()
    foreach ($rg in $rgNames) {
        $exists = az group exists --name $rg 2>&1
        if ($exists -eq 'true') {
            $existingRgs += $rg
        }
    }

    if ($existingRgs.Count -eq 0) {
        Write-Host "`n   No resource groups found for base name '$BaseName'. Nothing to delete." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "`n   The following resource groups will be PERMANENTLY DELETED:" -ForegroundColor Red
    foreach ($rg in $existingRgs) {
        Write-Host "     - $rg" -ForegroundColor Red
    }
    Write-Host ""
    $confirm = Read-Host "   Type 'yes' to confirm destruction (this cannot be undone)"
    if ($confirm -ne 'yes') {
        Write-Host "`n   Aborted. No resources were deleted." -ForegroundColor Yellow
        exit 0
    }

    foreach ($rg in $existingRgs) {
        Write-Step "Deleting resource group: $rg"
        az group delete --name $rg --yes --no-wait
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to initiate deletion for $rg"
        } else {
            Write-Ok "Deletion initiated for $rg (running in background)"
        }
    }

    Write-Header "Destroy Complete"
    Write-Host "   All resource group deletions have been initiated (--no-wait)." -ForegroundColor White
    Write-Host "   Deletions run asynchronously and may take several minutes to complete." -ForegroundColor Gray
    Write-Host "   Monitor progress: az group list --query `"[?starts_with(name,'$BaseName')]`" -o table" -ForegroundColor Gray
    exit 0
}

# --- Validate template --------------------------------------------------------
Write-Step "Validating Bicep template..."
$templateFile = Join-Path $ScriptRoot 'main.bicep'

if (-not (Test-Path $templateFile)) {
    Write-Fail "main.bicep not found at: $templateFile"
    exit 1
}

az bicep build --file $templateFile 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Bicep template has compilation errors. Run: az bicep build --file main.bicep"
    exit 1
}
Write-Ok "Template compiled successfully"

# =============================================================================
# 2. Generate Secure Admin Password
# =============================================================================
Write-Step "Generating secure admin password..."
# Cryptographically random 24-char password (uppercase, lowercase, digits, symbols)
$pwChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%&*'
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = [byte[]]::new(24)
$rng.GetBytes($bytes)
$AdminPassword = -join ($bytes | ForEach-Object { $pwChars[$_ % $pwChars.Length] })
# Ensure complexity: inject one of each class at random positions
$AdminPassword = $AdminPassword.Substring(0, 20) + 'Aa1@'
Write-Ok "Password generated (will be stored securely in Key Vault)"
Write-Host "   The password will NOT be displayed. Retrieve it after deployment with:" -ForegroundColor Gray
Write-Host "   az keyvault secret show --vault-name <keyvault-name> --name vm-admin-password --query value -o tsv" -ForegroundColor Gray

# =============================================================================
# 3. Domain Name
# =============================================================================
Write-Step "Active Directory domain configuration..."
$DomainName = Read-Host "   Enter the AD domain name (e.g., azlab.local)"
if ([string]::IsNullOrWhiteSpace($DomainName) -or $DomainName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
    Write-Fail "Invalid domain name. Must be a valid FQDN (e.g., azlab.local)"
    exit 1
}
Write-Ok "Domain: $DomainName (NetBIOS: $($DomainName.Split('.')[0].ToUpper()))"

# =============================================================================
# 3b. VPN Gateway — Self-Signed Certificate for P2S
# =============================================================================
Write-Step "VPN Gateway P2S certificate setup..."
$CertDir = Join-Path $ScriptRoot 'certs'
$RootCertPath = Join-Path $CertDir 'P2SRootCert.cer'
$ClientPfxPath = Join-Path $CertDir 'P2SClientCert.pfx'

if (Test-Path $RootCertPath) {
    Write-Ok "Existing root certificate found: $RootCertPath"
    $rootCertBase64 = Get-Content $RootCertPath -Raw
    # Strip PEM headers/footers and whitespace
    $rootCertBase64 = ($rootCertBase64 -replace '-----BEGIN CERTIFICATE-----' -replace '-----END CERTIFICATE-----').Trim() -replace '\r?\n',''
} else {
    Write-Host "   Generating self-signed root CA and client certificate..." -ForegroundColor Yellow

    if (-not (Test-Path $CertDir)) { New-Item -Path $CertDir -ItemType Directory -Force | Out-Null }

    # Create Root CA cert (self-signed, in CurrentUser\My)
    $rootCert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject "CN=P2SRootCert-$BaseName" `
        -KeySpec Signature `
        -KeyExportPolicy Exportable `
        -KeyLength 2048 `
        -HashAlgorithm sha256 `
        -KeyUsageProperty Sign `
        -KeyUsage CertSign `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(3)

    Write-Ok "Root CA created: $($rootCert.Subject) (Thumbprint: $($rootCert.Thumbprint))"

    # Create Client cert signed by root
    $clientCert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject "CN=P2SClientCert-$BaseName" `
        -KeySpec Signature `
        -KeyExportPolicy Exportable `
        -KeyLength 2048 `
        -HashAlgorithm sha256 `
        -Signer $rootCert `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(3)

    Write-Ok "Client cert created: $($clientCert.Subject) (Thumbprint: $($clientCert.Thumbprint))"

    # Export root cert public key as Base64 .cer
    $rootDer = $rootCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $rootCertBase64 = [Convert]::ToBase64String($rootDer)
    $rootPem = "-----BEGIN CERTIFICATE-----`r`n$rootCertBase64`r`n-----END CERTIFICATE-----"
    Set-Content -Path $RootCertPath -Value $rootPem -Encoding Ascii
    Write-Ok "Root cert exported: $RootCertPath"

    # Export client cert as PFX (protected with admin password)
    $pfxPwd = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    Export-PfxCertificate -Cert $clientCert -FilePath $ClientPfxPath -Password $pfxPwd | Out-Null
    Write-Ok "Client PFX exported: $ClientPfxPath (password = admin password in Key Vault)"

    # Add root cert to Trusted Root store (CurrentUser) so VPN client trusts it
    $trustedStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $trustedStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $trustedStore.Add($rootCert)
    $trustedStore.Close()
    Write-Ok "Root cert added to CurrentUser\\Trusted Root Certification Authorities"
}

$VpnRootCertData = $rootCertBase64

# =============================================================================
# 4. Deploy
# =============================================================================
$tierDescription = switch ($DeploymentTier) {
    1 { "Tier 1: Core Networking + AD (DCs, Bastion, Cloud Witness)" }
    2 { "Tier 2: + SQL Server VMs (5 VMs including AOAG at Site 2)" }
    3 { "Tier 3: Full Lab (Core + SQL + App servers: CAS + 3 child primaries)" }
}

Write-Header "Deployment Summary"
Write-Host "  Base Name       : $BaseName" -ForegroundColor White
Write-Host "  Location        : $Location" -ForegroundColor White
Write-Host "  Deployment Tier : $DeploymentTier — $tierDescription" -ForegroundColor White
Write-Host "  Domain Name     : $DomainName" -ForegroundColor White
Write-Host "  VPN Gateway     : P2S with self-signed certificate" -ForegroundColor White
Write-Host "  Admin Password  : (auto-generated, stored in Key Vault)" -ForegroundColor White
Write-Host "  Template        : $templateFile" -ForegroundColor White

if ($WhatIf) {
    Write-Header "What-If Preview (no resources will be created)"
    az deployment sub what-if `
        --location $Location `
        --template-file $templateFile `
        --parameters baseName=$BaseName location=$Location deploymentTier=$DeploymentTier adminPassword="$AdminPassword" domainName="$DomainName" deployerObjectId=$DeployerObjectId kvPrincipalType=$KvPrincipalType vpnRootCertData="$VpnRootCertData"

    Write-Host "`nWhat-If complete. No resources were modified." -ForegroundColor Cyan
    exit 0
}

Write-Header "Starting Deployment (Tier $DeploymentTier)"
$deploymentName = "$BaseName-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters baseName=$BaseName location=$Location deploymentTier=$DeploymentTier adminPassword="$AdminPassword" domainName="$DomainName" deployerObjectId=$DeployerObjectId kvPrincipalType=$KvPrincipalType vpnRootCertData="$VpnRootCertData" `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Deployment failed. Check the Azure portal or run:"
    Write-Host "   az deployment sub show --name $deploymentName --query properties.error" -ForegroundColor Gray
    exit 1
}

# =============================================================================
# 5. Post-Deployment Summary
# =============================================================================
Write-Header "Deployment Complete!"
Write-Host ""
Write-Host "  Resource Groups created:" -ForegroundColor White
Write-Host "    - $BaseName-rg-network    (VNet, NSGs, Bastion, VPN Gateway)" -ForegroundColor Gray
Write-Host "    - $BaseName-rg-identity   (DCs, Key Vault, Cloud Witness)" -ForegroundColor Gray
if ($DeploymentTier -ge 2) {
    Write-Host "    - $BaseName-rg-main       (SQL-CAS, SQL-PrimA$(if($DeploymentTier -ge 3){', CAS, PrimA'}))" -ForegroundColor Gray
    Write-Host "    - $BaseName-rg-site1      (SQL-PrimB$(if($DeploymentTier -ge 3){', PrimB'}))" -ForegroundColor Gray
    Write-Host "    - $BaseName-rg-site2      (SQL-PrimC AOAG, ILB$(if($DeploymentTier -ge 3){', PrimC'}))" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Cyan
Write-Host "  1) Retrieve admin password from Key Vault:" -ForegroundColor White
Write-Host "     az keyvault secret show --vault-name <keyvault-name> --name vm-admin-password --query value -o tsv" -ForegroundColor Gray
Write-Host "     (Find your KV name: az keyvault list --resource-group $BaseName-rg-identity --query [].name -o tsv)" -ForegroundColor Gray
Write-Host "  2) Connect via Bastion: Portal > $BaseName-bastion > Connect to VM" -ForegroundColor White
Write-Host "  3) Connect via VPN:" -ForegroundColor White
Write-Host "     a) Download VPN client: Portal > $BaseName-vpngw > Point-to-site > Download VPN client" -ForegroundColor Gray
Write-Host "     b) Client cert is already installed (CurrentUser\My)" -ForegroundColor Gray
Write-Host "     c) Run the downloaded VPN client configuration" -ForegroundColor Gray
Write-Host "     d) Connect using Windows VPN settings" -ForegroundColor Gray
Write-Host "     NOTE: VPN Gateway takes 25-45 min to provision. It may still be deploying." -ForegroundColor Yellow
Write-Host "  3) AD Domain Services (automated):" -ForegroundColor White
Write-Host "     - DC01 promoted as first DC in $DomainName" -ForegroundColor Gray
Write-Host "     - DC02 promoted as replica DC" -ForegroundColor Gray
Write-Host "     - OUs, security groups, service accounts, and gMSA created" -ForegroundColor Gray
Write-Host "     - VNet DNS set to DC IPs (10.0.1.4, 10.0.1.5)" -ForegroundColor Gray
Write-Host "  4) Domain-join remaining servers (SQL, App)" -ForegroundColor White
if ($DeploymentTier -ge 2) {
    Write-Host "  5) Install SQL Server on all SQL VMs" -ForegroundColor White
    Write-Host "  6) Configure WSFC with Cloud Witness, create AOAG on Site 2 SQL nodes" -ForegroundColor White
    Write-Host "  7) Create AG Listener using ILB IP 10.0.40.10 (probe port 59999)" -ForegroundColor White
}
if ($DeploymentTier -ge 3) {
    Write-Host "  8) Install application workloads on CAS and primary servers" -ForegroundColor White
    Write-Host "     - Primary A: local site, same subnet as CAS" -ForegroundColor White
    Write-Host "     - Primary B: remote site (Site 1 subnet)" -ForegroundColor White
    Write-Host "     - Primary C: remote site (Site 2 subnet, uses AOAG listener)" -ForegroundColor White
}

Write-Host ""
Write-Host "  To list deployed resources:" -ForegroundColor Gray
Write-Host "    az group list --tag env=lab --output table" -ForegroundColor Gray
Write-Host "    az vm list --query ""[?tags.project=='azure-lab'].[name,resourceGroup,location]"" -o table" -ForegroundColor Gray
Write-Host ""

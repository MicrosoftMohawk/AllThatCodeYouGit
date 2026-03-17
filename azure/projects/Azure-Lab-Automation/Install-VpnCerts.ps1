<#
.SYNOPSIS
    Installs P2S VPN certificates on a secondary workstation.

.DESCRIPTION
    This script automates VPN setup on a machine that was NOT used to run the original deploy.ps1.
    It imports the root CA certificate and client PFX into the local certificate stores.

    Prerequisites:
    - The certs/ folder (P2SRootCert.cer + P2SClientCert.pfx) from the original deployment
    - The PFX password (same as the admin password stored in Key Vault)

.PARAMETER BaseName
    The base name used during deployment (e.g., azlab). Used to locate the VPN Gateway.

.PARAMETER CertDir
    Path to the directory containing P2SRootCert.cer and P2SClientCert.pfx.
    Defaults to the certs/ subfolder next to this script.

.PARAMETER PfxPassword
    Password for the client PFX file. If not provided, will prompt securely.
    This is the same admin password stored in the Key Vault secret 'vm-admin-password'.

.EXAMPLE
    .\Install-VpnCerts.ps1 -BaseName azlab
    # Prompts for PFX password, imports certs

.EXAMPLE
    .\Install-VpnCerts.ps1 -BaseName azlab -CertDir C:\MyCerts
    # Import certs from custom path
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [string]$CertDir,

    [SecureString]$PfxPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Helper functions ────────────────────────────────────────────────────────
function Write-Step  { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$msg) Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "   [WARN] $msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$msg) Write-Host "   [ERROR] $msg" -ForegroundColor Red }

# ─── Resolve certificate directory ───────────────────────────────────────────
if (-not $CertDir) {
    $CertDir = Join-Path $PSScriptRoot 'certs'
}

$RootCertPath  = Join-Path $CertDir 'P2SRootCert.cer'
$ClientPfxPath = Join-Path $CertDir 'P2SClientCert.pfx'

Write-Step "Validating certificate files..."

if (-not (Test-Path $RootCertPath)) {
    Write-Err "Root certificate not found: $RootCertPath"
    Write-Host "   Copy the certs/ folder from the original deployment machine." -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $ClientPfxPath)) {
    Write-Err "Client PFX not found: $ClientPfxPath"
    Write-Host "   Copy the certs/ folder from the original deployment machine." -ForegroundColor Yellow
    exit 1
}

Write-Ok "Root cert: $RootCertPath"
Write-Ok "Client PFX: $ClientPfxPath"

# ─── Prompt for PFX password if not provided ─────────────────────────────────
if (-not $PfxPassword) {
    Write-Host ""
    Write-Host "   The PFX password is the admin password from the deployment." -ForegroundColor Yellow
    Write-Host "   Retrieve it from Key Vault: az keyvault secret show --vault-name $BaseName-kv --name vm-admin-password --query value -o tsv" -ForegroundColor DarkGray
    Write-Host ""
    $PfxPassword = Read-Host "   Enter PFX password" -AsSecureString
}

# ─── Step 1: Import root certificate into Trusted Root ───────────────────────
Write-Step "Importing root certificate into CurrentUser\Trusted Root Certification Authorities..."

try {
    $rootCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($RootCertPath)

    $trustedStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $trustedStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    # Check if already installed
    $existing = $trustedStore.Certificates | Where-Object { $_.Thumbprint -eq $rootCert.Thumbprint }
    if ($existing) {
        Write-Ok "Root cert already in Trusted Root (Thumbprint: $($rootCert.Thumbprint))"
    } else {
        $trustedStore.Add($rootCert)
        Write-Ok "Root cert imported (Subject: $($rootCert.Subject), Thumbprint: $($rootCert.Thumbprint))"
    }
    $trustedStore.Close()
} catch {
    Write-Err "Failed to import root certificate: $_"
    exit 1
}

# ─── Step 2: Import client PFX into Personal store ──────────────────────────
Write-Step "Importing client certificate into CurrentUser\My (Personal)..."

try {
    $importedCert = Import-PfxCertificate `
        -FilePath $ClientPfxPath `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -Password $PfxPassword `
        -Exportable

    Write-Ok "Client cert imported (Subject: $($importedCert.Subject), Thumbprint: $($importedCert.Thumbprint))"
} catch {
    Write-Err "Failed to import client PFX: $_"
    Write-Host "   Verify the PFX password is correct." -ForegroundColor Yellow
    Write-Host "   If an incremental deploy regenerated the admin password (Key Vault was" -ForegroundColor Yellow
    Write-Host "   unreachable behind its private endpoint), the PFX on disk may have been" -ForegroundColor Yellow
    Write-Host "   re-exported with the new password. Re-run deploy.ps1 on the original" -ForegroundColor Yellow
    Write-Host "   machine and copy the updated certs/ folder to this workstation." -ForegroundColor Yellow
    exit 1
}

# ─── Step 3: Download VPN client ─────────────────────────────────────────────
Write-Warn "Download the VPN client configuration manually from the Azure Portal:"
Write-Host "   Azure Portal -> $BaseName-vpngw -> Point-to-site configuration -> Download VPN client" -ForegroundColor Yellow

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  VPN Certificate Setup Complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Root cert:   Installed in CurrentUser\Trusted Root" -ForegroundColor White
Write-Host "  Client cert: Installed in CurrentUser\My (Personal)" -ForegroundColor White
Write-Host ""
Write-Host "  To connect:" -ForegroundColor Cyan
Write-Host "    1. Install the VPN client (if not already done)" -ForegroundColor White
Write-Host "    2. Windows Settings -> Network & Internet -> VPN" -ForegroundColor White
Write-Host "    3. Select '$BaseName-vpngw' and click Connect" -ForegroundColor White
Write-Host "    4. You'll receive a 172.16.0.x IP with access to 10.0.0.0/16" -ForegroundColor White
Write-Host ""

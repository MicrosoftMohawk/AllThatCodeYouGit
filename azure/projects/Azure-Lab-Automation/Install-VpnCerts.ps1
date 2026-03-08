<#
.SYNOPSIS
    Installs P2S VPN certificates on a secondary workstation and downloads the VPN client configuration.

.DESCRIPTION
    This script automates VPN setup on a machine that was NOT used to run the original deploy.ps1.
    It imports the root CA certificate and client PFX into the local certificate stores, then
    downloads the VPN client configuration package from Azure.

    Prerequisites:
    - The certs/ folder (P2SRootCert.cer + P2SClientCert.pfx) from the original deployment
    - Azure CLI installed and authenticated (for VPN client download)
    - The PFX password (same as the admin password stored in Key Vault)

.PARAMETER BaseName
    The base name used during deployment (e.g., azlab). Used to locate the VPN Gateway.

.PARAMETER CertDir
    Path to the directory containing P2SRootCert.cer and P2SClientCert.pfx.
    Defaults to the certs/ subfolder next to this script.

.PARAMETER PfxPassword
    Password for the client PFX file. If not provided, will prompt securely.
    This is the same admin password stored in the Key Vault secret 'vm-admin-password'.

.PARAMETER SkipVpnClientDownload
    Skip downloading the VPN client configuration from Azure (useful if Az CLI is not installed).

.EXAMPLE
    .\Install-VpnCerts.ps1 -BaseName azlab
    # Prompts for PFX password, imports certs, downloads VPN client config

.EXAMPLE
    .\Install-VpnCerts.ps1 -BaseName azlab -CertDir C:\MyCerts -SkipVpnClientDownload
    # Import certs from custom path, skip VPN client download
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [string]$CertDir,

    [SecureString]$PfxPassword,

    [switch]$SkipVpnClientDownload
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

# ─── Step 3: Download VPN client configuration ──────────────────────────────
if ($SkipVpnClientDownload) {
    Write-Warn "Skipping VPN client download (-SkipVpnClientDownload specified)"
    Write-Host "   Download manually: Azure Portal -> $BaseName-vpngw -> Point-to-site configuration -> Download VPN client" -ForegroundColor Yellow
} else {
    Write-Step "Downloading VPN client configuration from Azure..."

    # Check Az CLI is available
    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        Write-Warn "Azure CLI not found. Skipping VPN client download."
        Write-Host "   Install Azure CLI: winget install Microsoft.AzureCLI" -ForegroundColor Yellow
        Write-Host "   Or download manually: Azure Portal -> $BaseName-vpngw -> Point-to-site configuration -> Download VPN client" -ForegroundColor Yellow
    } else {
        # Verify logged in
        $acct = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "   Not logged in. Opening browser for Azure login..." -ForegroundColor Yellow
            az login | Out-Null
        }

        $rgName  = "$BaseName-rg-network"
        $gwName  = "$BaseName-vpngw"
        $outDir  = Join-Path $CertDir 'vpn-client'

        Write-Host "   Resource Group: $rgName" -ForegroundColor DarkGray
        Write-Host "   VPN Gateway:    $gwName" -ForegroundColor DarkGray

        try {
            # Generate VPN client package URL
            $vpnUrl = az network vnet-gateway vpn-client generate `
                --resource-group $rgName `
                --name $gwName `
                --output tsv 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Err "Failed to generate VPN client package: $vpnUrl"
                Write-Host "   Verify the VPN Gateway exists and has P2S configured." -ForegroundColor Yellow
                Write-Host "   Download manually: Azure Portal -> $BaseName-vpngw -> Point-to-site configuration -> Download VPN client" -ForegroundColor Yellow
            } else {
                # Download the ZIP
                if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
                $zipPath = Join-Path $outDir 'VpnClient.zip'

                Write-Host "   Downloading VPN client package..." -ForegroundColor Yellow
                Invoke-WebRequest -Uri $vpnUrl -OutFile $zipPath -UseBasicParsing

                # Extract
                $extractDir = Join-Path $outDir 'VpnClient'
                if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
                Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

                Write-Ok "VPN client downloaded and extracted to: $extractDir"
                Write-Host ""
                Write-Host "   Next steps:" -ForegroundColor Cyan
                Write-Host "   1. Open the extracted folder: $extractDir" -ForegroundColor White
                Write-Host "   2. Run the installer for your architecture (WindowsAmd64/VpnClientSetupAmd64.exe)" -ForegroundColor White
                Write-Host "   3. Connect: Windows Settings -> Network & Internet -> VPN -> $gwName -> Connect" -ForegroundColor White
                Write-Host ""

                # Offer to open the folder
                $openFolder = Read-Host "   Open the VPN client folder now? (Y/n)"
                if ($openFolder -ne 'n') {
                    Start-Process explorer.exe -ArgumentList $extractDir
                }
            }
        } catch {
            Write-Err "Failed to download VPN client: $_"
            Write-Host "   Download manually: Azure Portal -> $BaseName-vpngw -> Point-to-site configuration -> Download VPN client" -ForegroundColor Yellow
        }
    }
}

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

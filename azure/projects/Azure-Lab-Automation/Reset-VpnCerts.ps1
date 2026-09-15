<#
.SYNOPSIS
    Regenerates the P2S VPN certificates for an existing lab, updates the VPN
    gateway, and stores the new certificates in Key Vault.

.DESCRIPTION
    Use this when the VPN certificates are lost or corrupted and must be recreated
    from scratch, independently of a full deploy.ps1 run. It:
      1. Generates a brand-new self-signed root CA + client certificate.
      2. Updates the VPN gateway's root certificate (control plane).
      3. Stores the new certs (and optionally the admin password) in Key Vault
         via a control-plane ARM deployment.

    All Azure operations are control-plane, so this works even when NOT connected
    to the VPN. Because the Key Vault is private, the current admin password cannot
    be read off-VPN — so in the default (preserve) mode you must supply it, or the
    script will prompt for it, so the new PFX matches the existing VMs and the
    vm-admin-password secret.

    Rotating the root certificate invalidates every previously-issued client
    certificate. After running this, re-run Install-VpnCerts.ps1 on each machine.

.PARAMETER BaseName
    Base name of the lab (max 10 characters).

.PARAMETER SubscriptionId
    Target subscription ID. If omitted, uses the current az CLI default.

.PARAMETER AdminPassword
    Current admin password, used to encrypt the new PFX so it keeps matching the
    VMs and the vm-admin-password secret. If omitted (and not -RotatePassword),
    the script tries to read it from Key Vault (works only on VPN) and otherwise
    prompts.

.PARAMETER RotatePassword
    Generate a NEW admin password and store it in Key Vault. WARNING: this desyncs
    the vm-admin-password secret from the VMs' actual local admin accounts.

.PARAMETER ExportDir
    Optional folder to also write portable cert files (P2SRootCert-<name>.cer and
    P2SClientCert-<name>.pfx). Copy these to a machine that cannot reach the private
    Key Vault and import them with Install-VpnCerts.ps1 -FromLocalFiles.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\Reset-VpnCerts.ps1 -BaseName azlab
    # Preserve mode: prompts for the current admin password, regenerates certs,
    # updates the gateway, and stores the new certs in Key Vault.

.EXAMPLE
    .\Reset-VpnCerts.ps1 -BaseName azlab -ExportDir C:\vpncerts
    # Also writes portable .cer/.pfx files for offline machines.

.EXAMPLE
    .\Reset-VpnCerts.ps1 -BaseName azlab -RotatePassword -Force
    # Regenerate certs AND rotate the admin password (desyncs from VMs).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [string]$SubscriptionId,

    [SecureString]$AdminPassword,

    [switch]$RotatePassword,

    [string]$ExportDir,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Helper functions ────────────────────────────────────────────────────────
function Write-Step  { param([string]$msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$msg) Write-Host "   [OK] $msg" -ForegroundColor Green }
function Write-Warn  { param([string]$msg) Write-Host "   [WARN] $msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$msg) Write-Host "   [ERROR] $msg" -ForegroundColor Red }

$ScriptRoot = $PSScriptRoot
$rgIdentity = "$BaseName-rg-identity"
$rgNetwork  = "$BaseName-rg-network"
$gwName     = "$BaseName-vpngw"
$rootCertSubject   = "CN=P2SRootCert-$BaseName"
$clientCertSubject = "CN=P2SClientCert-$BaseName"
$rootCertName      = "P2SRootCert-$BaseName"
$secretsTemplate   = Join-Path $ScriptRoot 'modules/security/vpnCertSecrets.bicep'

# ─── Preflight: Azure CLI session ────────────────────────────────────────────
Write-Step "Validating Azure CLI session..."
az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Azure CLI is not logged in. Run 'az login' first."
    exit 1
}
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to set subscription '$SubscriptionId'."; exit 1 }
}
Write-Ok "Azure CLI session valid."

# ─── Preflight: resource groups, Key Vault, gateway ──────────────────────────
Write-Step "Locating the lab's Key Vault and VPN gateway..."
if ((az group exists --name $rgIdentity 2>&1) -ne 'true') {
    Write-Err "Resource group '$rgIdentity' not found. Is the lab deployed under BaseName '$BaseName'?"
    exit 1
}
if ((az group exists --name $rgNetwork 2>&1) -ne 'true') {
    Write-Err "Resource group '$rgNetwork' not found."
    exit 1
}

$kvName = az keyvault list --resource-group $rgIdentity --query "[0].name" -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kvName)) {
    Write-Err "Could not find a Key Vault in '$rgIdentity'."
    exit 1
}
$kvName = $kvName.Trim()
Write-Ok "Key Vault: $kvName"

az network vnet-gateway show --resource-group $rgNetwork --name $gwName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "VPN gateway '$gwName' not found in '$rgNetwork'. Nothing to update."
    exit 1
}
Write-Ok "VPN gateway: $gwName"

if (-not (Test-Path $secretsTemplate)) {
    Write-Err "Bicep template not found: $secretsTemplate"
    exit 1
}

# ─── Confirmation ────────────────────────────────────────────────────────────
if (-not $Force) {
    Write-Host ""
    Write-Warn "This regenerates the VPN root certificate for '$BaseName'."
    Write-Host "   Every client certificate currently installed on any machine will STOP" -ForegroundColor Yellow
    Write-Host "   working until you re-run Install-VpnCerts.ps1 on that machine." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "   Type 'yes' to continue"
    if ($confirm -ne 'yes') { Write-Host "   Aborted." -ForegroundColor Gray; exit 0 }
}

# ─── Resolve the PFX / admin password ────────────────────────────────────────
Write-Step "Resolving admin password for the new client PFX..."
$UpdateAdminPassword = $false
$PlainPassword = $null

if ($RotatePassword) {
    # Cryptographically random 24-char password; charset avoids cmd.exe-hostile
    # characters so it stays safe when passed to az.cmd on Windows.
    $pwChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#_-+'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(24)
    $rng.GetBytes($bytes)
    $PlainPassword = (-join ($bytes | ForEach-Object { $pwChars[$_ % $pwChars.Length] })).Substring(0, 20) + 'Aa1@'
    $UpdateAdminPassword = $true
    Write-Warn "Rotating the admin password. The vm-admin-password secret will NO LONGER match"
    Write-Host "   the VMs' actual local admin accounts (Bastion logins using it will break)." -ForegroundColor Yellow
    Write-Ok "New admin password generated (will be stored in Key Vault)."
} else {
    if ($AdminPassword) {
        $PlainPassword = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
    } else {
        # Try to read the current password from Key Vault (works only on VPN).
        $kvPw = az keyvault secret show --vault-name $kvName --name vm-admin-password --query value -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($kvPw)) {
            $PlainPassword = $kvPw.Trim()
            Write-Ok "Current admin password retrieved from Key Vault."
        } else {
            Write-Host "   Key Vault is unreachable (private endpoint / not on VPN)." -ForegroundColor Yellow
            Write-Host "   Enter the CURRENT admin password so the new PFX keeps matching the VMs." -ForegroundColor Yellow
            $secure = Read-Host "   Current admin password" -AsSecureString
            $PlainPassword = [System.Net.NetworkCredential]::new('', $secure).Password
        }
    }
    if ([string]::IsNullOrWhiteSpace($PlainPassword)) {
        Write-Err "No admin password provided. Cannot export the client PFX."
        exit 1
    }
}

# ─── Regenerate certificates from scratch ────────────────────────────────────
Write-Step "Regenerating VPN certificates from scratch..."

# Remove any existing certs for this BaseName so generation is truly fresh.
Get-ChildItem -Path 'Cert:\CurrentUser\My' |
    Where-Object { $_.Subject -eq $rootCertSubject -or $_.Subject -eq $clientCertSubject } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$rootCert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $rootCertSubject `
    -KeySpec Signature `
    -KeyExportPolicy Exportable `
    -KeyLength 2048 `
    -HashAlgorithm sha256 `
    -KeyUsageProperty Sign `
    -KeyUsage CertSign `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddYears(3)
Write-Ok "Root CA created: $($rootCert.Subject) (Thumbprint: $($rootCert.Thumbprint))"

$clientCert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $clientCertSubject `
    -KeySpec Signature `
    -KeyExportPolicy Exportable `
    -KeyLength 2048 `
    -HashAlgorithm sha256 `
    -Signer $rootCert `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddYears(3)
Write-Ok "Client cert created: $($clientCert.Subject) (Thumbprint: $($clientCert.Thumbprint))"

# ─── Export + Base64-encode ──────────────────────────────────────────────────
$TempDir = Join-Path $env:TEMP "vpncerts-reset-$BaseName"
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
$RootCertPath  = Join-Path $TempDir "P2SRootCert-$BaseName.cer"
$ClientPfxPath = Join-Path $TempDir "P2SClientCert-$BaseName.pfx"

$rootDer = $rootCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$rootCertBase64 = [Convert]::ToBase64String($rootDer)
$rootPem = "-----BEGIN CERTIFICATE-----`r`n$rootCertBase64`r`n-----END CERTIFICATE-----"
Set-Content -Path $RootCertPath -Value $rootPem -Encoding Ascii

$pfxPwd = ConvertTo-SecureString $PlainPassword -AsPlainText -Force
Export-PfxCertificate -Cert $clientCert -FilePath $ClientPfxPath `
    -Password $pfxPwd -CryptoAlgorithmOption TripleDES_SHA1 | Out-Null
$clientCertBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ClientPfxPath))
Write-Ok "New certificates exported and encoded."

# Add the new root to Trusted Root so this machine can use the VPN too.
$trustedStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
$trustedStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
if (-not ($trustedStore.Certificates | Where-Object { $_.Thumbprint -eq $rootCert.Thumbprint })) {
    $trustedStore.Add($rootCert)
}
$trustedStore.Close()

# ─── Update the VPN gateway root certificate (control plane) ─────────────────
Write-Step "Updating the VPN gateway root certificate (this reconfigures the gateway)..."
# az --public-cert-data requires a FILE path containing the raw base64 (no PEM headers).
$RootB64Path = Join-Path $TempDir "P2SRootCert-$BaseName.b64"
Set-Content -Path $RootB64Path -Value $rootCertBase64 -NoNewline -Encoding Ascii

az network vnet-gateway root-cert delete `
    --resource-group $rgNetwork --gateway-name $gwName --name $rootCertName 2>&1 | Out-Null
$gwResult = az network vnet-gateway root-cert create `
    --resource-group $rgNetwork --gateway-name $gwName `
    --name $rootCertName --public-cert-data $RootB64Path 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to update the gateway root certificate."
    Write-Host "   $gwResult" -ForegroundColor DarkGray
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Ok "Gateway root certificate updated: $rootCertName"

# ─── Store the new certs (+ password) in Key Vault (control plane) ───────────
Write-Step "Storing the new certificates in Key Vault '$kvName'..."
$deployName = "reset-vpn-certs-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
$secretParams = @(
    "keyVaultName=$kvName"
    "vpnRootCertData=$rootCertBase64"
    "vpnClientCertData=$clientCertBase64"
    "updateAdminPassword=$($UpdateAdminPassword.ToString().ToLower())"
)
if ($UpdateAdminPassword) { $secretParams += "adminPassword=$PlainPassword" }

az deployment group create `
    --resource-group $rgIdentity `
    --name $deployName `
    --template-file $secretsTemplate `
    --parameters @secretParams 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to store certificates in Key Vault."
    Write-Host "   See details:  az deployment group show -g $rgIdentity -n $deployName" -ForegroundColor DarkGray
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Ok "Key Vault secrets updated: vpn-root-cert, vpn-client-cert-pfx$(if ($UpdateAdminPassword) { ', vm-admin-password' })"

# ─── Optional: export portable cert files for offline / never-connected machines ─
$ExportedRoot = $null
$ExportedPfx = $null
if ($ExportDir) {
    New-Item -Path $ExportDir -ItemType Directory -Force | Out-Null
    $ExportedRoot = Join-Path $ExportDir "P2SRootCert-$BaseName.cer"
    $ExportedPfx  = Join-Path $ExportDir "P2SClientCert-$BaseName.pfx"
    Copy-Item -Path $RootCertPath -Destination $ExportedRoot -Force
    Copy-Item -Path $ClientPfxPath -Destination $ExportedPfx -Force
    Write-Ok "Portable cert files written to: $ExportDir"
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  VPN Certificates Regenerated" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Gateway root cert : $rootCertName (updated in $gwName)" -ForegroundColor White
Write-Host "  Key Vault secrets : vpn-root-cert, vpn-client-cert-pfx" -ForegroundColor White
if ($UpdateAdminPassword) {
    Write-Host "  Admin password    : ROTATED and stored (no longer matches existing VMs)" -ForegroundColor Yellow
} else {
    Write-Host "  Admin password    : preserved (PFX matches existing VMs)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. The gateway takes a few minutes to apply the new root cert." -ForegroundColor White
Write-Host "    2. On machines that can reach the Key Vault (on VPN), re-run:" -ForegroundColor White
Write-Host "         .\Install-VpnCerts.ps1 -BaseName $BaseName" -ForegroundColor White
Write-Host "       (pulls the new certs from Key Vault and imports them)" -ForegroundColor White
if ($ExportedPfx) {
    Write-Host "    3. For a machine that CANNOT reach the Key Vault (never on VPN):" -ForegroundColor White
    Write-Host "       copy these files to it, then run:" -ForegroundColor White
    Write-Host "         $ExportedRoot" -ForegroundColor DarkGray
    Write-Host "         $ExportedPfx" -ForegroundColor DarkGray
    Write-Host "         .\Install-VpnCerts.ps1 -BaseName $BaseName -FromLocalFiles -CertDir <folder>" -ForegroundColor White
    Write-Host "       (PFX password = $(if ($UpdateAdminPassword) { 'the NEW admin password' } else { 'the current admin password' }))" -ForegroundColor DarkGray
} else {
    Write-Host "    3. For a machine that CANNOT reach the Key Vault, re-run with -ExportDir <folder>" -ForegroundColor White
    Write-Host "       to produce portable files, copy them over, then use:" -ForegroundColor White
    Write-Host "         .\Install-VpnCerts.ps1 -BaseName $BaseName -FromLocalFiles -CertDir <folder>" -ForegroundColor White
}
Write-Host ""

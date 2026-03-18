<#
.SYNOPSIS
    Install Microsoft Entra Connect Sync on the target server.
    Runs as a VM RunCommand after the server is domain-joined.

.DESCRIPTION
    Pre-installs Entra Connect Sync by:
    1. Enforcing TLS 1.2 as the default security protocol
    2. Downloading the latest Entra Connect installer from Microsoft
    3. Running a silent installation

    The Entra Connect configuration wizard must be completed manually via
    RDP/Bastion after installation. The wizard requires interactive
    authentication with an Entra ID Global Administrator account.

.NOTES
    Post-install manual steps:
    1. RDP/Bastion into this server
    2. Launch the Entra Connect wizard from the desktop shortcut
    3. Select "Customize" for custom configuration
    4. Choose "Password Hash Synchronization" (PHS) as the sign-on method
    5. Authenticate with Entra ID Global Administrator credentials
    6. Connect to on-prem AD forest using Enterprise Admin credentials
    7. Configure OU filtering (select Lab Accounts, Lab Groups, Lab Servers)
    8. Enable "Azure AD Domain and OU filtering"
    9. Optional: Enable device writeback for hybrid Entra ID join
    10. Start initial synchronization
#>

$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\WindowsTemp\Install-EntraConnect.log' -Append

# ============================================================================
# Enforce TLS 1.2
# ============================================================================
Write-Output 'Configuring TLS 1.2 as default protocol...'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Set TLS 1.2 as default for .NET Framework (machine-wide)
$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
)
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Set-ItemProperty -Path $path -Name 'SchUseStrongCrypto' -Value 1 -Type DWord
        Set-ItemProperty -Path $path -Name 'SystemDefaultTlsVersions' -Value 1 -Type DWord
    }
}
Write-Output '  TLS 1.2 configured'

# ============================================================================
# Download Entra Connect
# ============================================================================
$downloadUrl = 'https://download.microsoft.com/download/B/0/0/B00291D0-5A83-4DE7-86F5-980BC00DE05A/AzureADConnect.msi'
$installerPath = 'C:\WindowsTemp\AzureADConnect.msi'

Write-Output 'Downloading Microsoft Entra Connect...'
if (Test-Path $installerPath) {
    Write-Output '  Installer already exists, re-downloading for latest version...'
    Remove-Item $installerPath -Force
}

try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($downloadUrl, $installerPath)
    $fileSize = (Get-Item $installerPath).Length / 1MB
    Write-Output "  Downloaded: $installerPath ($([math]::Round($fileSize, 1)) MB)"
} catch {
    throw "Failed to download Entra Connect: $_"
}

# ============================================================================
# Install Entra Connect (silent)
# ============================================================================
Write-Output 'Installing Microsoft Entra Connect (silent)...'
$msiArgs = '/i', $installerPath, '/quiet', '/norestart', '/log', 'C:\WindowsTemp\AzureADConnect-Install.log'
$process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
    Write-Output "  Installation completed (exit code: $($process.ExitCode))"
    if ($process.ExitCode -eq 3010) {
        Write-Output '  NOTE: A reboot is required to complete installation'
    }
} else {
    throw "Entra Connect installation failed with exit code: $($process.ExitCode). Check C:\WindowsTemp\AzureADConnect-Install.log"
}

# ============================================================================
# Summary
# ============================================================================
Write-Output ''
Write-Output '=========================================='
Write-Output ' Entra Connect Installation Complete'
Write-Output '=========================================='
Write-Output ' Installer path : C:\WindowsTemp\AzureADConnect.msi'
Write-Output ' Install log    : C:\WindowsTemp\AzureADConnect-Install.log'
Write-Output ''
Write-Output ' NEXT STEPS (manual):'
Write-Output '   1. RDP or Bastion into this server'
Write-Output '   2. Launch "Azure AD Connect" from the desktop or Start menu'
Write-Output '   3. Complete the configuration wizard:'
Write-Output '      - Sign-on method: Password Hash Synchronization (PHS)'
Write-Output '      - Entra ID: Authenticate with Global Administrator'
Write-Output '      - On-prem AD: Connect using Enterprise Admin credentials'
Write-Output '      - OU filtering: Select Lab Accounts, Lab Groups, Lab Servers'
Write-Output '      - Optional features: Device writeback (for hybrid Entra join)'
Write-Output '   4. Start initial synchronization'
Write-Output '=========================================='

Stop-Transcript

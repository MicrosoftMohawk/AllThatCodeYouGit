<#
.SYNOPSIS
    Install management tools on the Entra ID-joined management VM.
    Runs as a VM RunCommand after the VM is provisioned and joined.

.DESCRIPTION
    Installs the following tools for hybrid environment management:
    - RSAT (Remote Server Administration Tools) for AD, DNS, Group Policy
    - Azure PowerShell module (Az)
    - Azure CLI
    - SQL Server PowerShell module (SqlServer)
#>

$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\WindowsTemp\Install-ManagementTools.log' -Append

# ============================================================================
# Install RSAT Features
# ============================================================================
Write-Output 'Installing RSAT features...'
$rsatFeatures = @(
    'RSAT-AD-Tools'
    'RSAT-AD-AdminCenter'
    'RSAT-AD-PowerShell'
    'RSAT-DNS-Server'
    'GPMC'
)

foreach ($feature in $rsatFeatures) {
    $installed = Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue
    if ($installed -and $installed.Installed) {
        Write-Output "  Already installed: $feature"
    } else {
        Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction Stop
        Write-Output "  Installed: $feature"
    }
}

# ============================================================================
# Install PowerShell Modules
# ============================================================================
Write-Output 'Installing PowerShell modules...'

# Trust PSGallery to avoid interactive prompts
if ((Get-PSRepository -Name 'PSGallery').InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
}

# Install NuGet provider if needed
$nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Write-Output '  NuGet package provider installed'
}

$modules = @('Az', 'SqlServer')
foreach ($mod in $modules) {
    if (Get-Module -Name $mod -ListAvailable -ErrorAction SilentlyContinue) {
        Write-Output "  Already installed: $mod module"
    } else {
        Write-Output "  Installing $mod module (this may take a few minutes)..."
        Install-Module -Name $mod -Scope AllUsers -Force -AllowClobber
        Write-Output "  Installed: $mod module"
    }
}

# ============================================================================
# Install Azure CLI
# ============================================================================
Write-Output 'Installing Azure CLI...'
if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Output '  Azure CLI already installed'
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cliUrl = 'https://aka.ms/installazurecliwindowsx64'
    $cliInstaller = 'C:\WindowsTemp\AzureCLI.msi'

    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($cliUrl, $cliInstaller)

    $msiArgs = '/i', $cliInstaller, '/quiet', '/norestart', '/log', 'C:\WindowsTemp\AzureCLI-Install.log'
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Output "  Azure CLI installed (exit code: $($proc.ExitCode))"
    } else {
        Write-Output "  WARNING: Azure CLI install returned exit code $($proc.ExitCode). Check C:\WindowsTemp\AzureCLI-Install.log"
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Output ''
Write-Output '=========================================='
Write-Output ' Management Tools Installation Complete'
Write-Output '=========================================='
Write-Output ' RSAT: AD Tools, DNS Server, Group Policy Management Console'
Write-Output ' PowerShell: Az module, SqlServer module'
Write-Output ' CLI: Azure CLI'
Write-Output '=========================================='

Stop-Transcript

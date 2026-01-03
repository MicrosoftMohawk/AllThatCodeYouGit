<#
.SYNOPSIS
    Connect to an Azure VM via RDP using Azure Bastion Native Client Support

.DESCRIPTION
    This script connects to an Azure VM through Azure Bastion using the native RDP client.
    Requires Azure CLI to be installed and Azure Bastion to have native client support enabled.

.PARAMETER VMName
    The name of the Azure Virtual Machine to connect to

.PARAMETER ResourceGroupName
    The name of the resource group containing the VM

.PARAMETER BastionName
    The name of the Azure Bastion resource

.PARAMETER SubscriptionId
    (Optional) The Azure subscription ID. If not provided, uses the current subscription.

.PARAMETER UseAllMonitors
    (Optional) If specified, attempts to use all monitors. Note: The az network bastion rdp command
    uses default RDP settings and may not honor this parameter. Single monitor is typical default.

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion"

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -UseAllMonitors
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$BastionName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$UseAllMonitors
)

# Function to check if Azure CLI is installed
function Test-AzureCLI {
    try {
        $azVersion = az version --output json 2>$null | ConvertFrom-Json
        if ($azVersion) {
            Write-Host "✓ Azure CLI is installed (Version: $($azVersion.'azure-cli'))" -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Host "✗ Azure CLI is not installed" -ForegroundColor Red
        Write-Host "Please install Azure CLI from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli" -ForegroundColor Yellow
        return $false
    }
    return $false
}

# Function to check Azure CLI login status
function Test-AzureLogin {
    try {
        $account = az account show 2>$null | ConvertFrom-Json
        if ($account) {
            Write-Host "✓ Already logged in to Azure as: $($account.user.name)" -ForegroundColor Green
            Write-Host "  Subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan
            return $true
        }
    }
    catch {
        Write-Host "✗ Not logged in to Azure" -ForegroundColor Red
        return $false
    }
    return $false
}

# Function to check and configure preview extensions
function Enable-PreviewExtensions {
    Write-Host "Configuring Azure CLI to allow preview extensions..." -ForegroundColor Yellow
    az config set extension.dynamic_install_allow_preview=true 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Preview extensions enabled" -ForegroundColor Green
        return $true
    } else {
        Write-Host "⚠ Warning: Could not enable preview extensions" -ForegroundColor Yellow
        return $false
    }
}

# Function to check and install bastion extension
function Test-BastionExtension {
    Write-Host "Checking for Azure Bastion extension..." -ForegroundColor Yellow
    $extensions = az extension list --output json 2>$null | ConvertFrom-Json
    $bastionExt = $extensions | Where-Object { $_.name -eq "bastion" }
    
    if ($bastionExt) {
        Write-Host "✓ Bastion extension is installed (Version: $($bastionExt.version))" -ForegroundColor Green
        return $true
    } else {
        Write-Host "✗ Bastion extension is not installed" -ForegroundColor Red
        Write-Host "The Azure Bastion extension is required for native client support." -ForegroundColor Yellow
        
        $response = Read-Host "Would you like to install it now? (Y/N)"
        if ($response -eq 'Y' -or $response -eq 'y') {
            Write-Host "Installing Azure Bastion extension..." -ForegroundColor Yellow
            az extension add --name bastion --allow-preview true 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Bastion extension installed successfully" -ForegroundColor Green
                return $true
            } else {
                Write-Host "✗ Failed to install Bastion extension" -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "✗ Bastion extension is required to continue" -ForegroundColor Red
            return $false
        }
    }
}

# Main script execution
Write-Host "`n=== Azure Bastion RDP Connection Script ===" -ForegroundColor Cyan
Write-Host "Target VM: $VMName" -ForegroundColor White
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "Bastion: $BastionName`n" -ForegroundColor White

# Step 1: Check if Azure CLI is installed
if (-not (Test-AzureCLI)) {
    exit 1
}

# Step 2: Check login status
if (-not (Test-AzureLogin)) {
    Write-Host "`nAttempting to log in to Azure..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Failed to log in to Azure" -ForegroundColor Red
        exit 1
    }
}
# Step 2.5: Enable preview extensions and check for bastion extension
Write-Host "" # Blank line for readability
Enable-PreviewExtensions

if (-not (Test-BastionExtension)) {
    exit 1
}
# Step 3: Set subscription if provided
if ($SubscriptionId) {
    Write-Host "`nSetting subscription to: $SubscriptionId" -ForegroundColor Yellow
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Failed to set subscription" -ForegroundColor Red
        exit 1
    }
}

# Step 4: Get VM Resource ID
Write-Host "`nRetrieving VM information..." -ForegroundColor Yellow
$vmResourceId = az vm show --name $VMName --resource-group $ResourceGroupName --query "id" -o tsv 2>$null

if (-not $vmResourceId) {
    Write-Host "✗ Failed to find VM: $VMName in resource group: $ResourceGroupName" -ForegroundColor Red
    exit 1
}

Write-Host "✓ VM found: $vmResourceId" -ForegroundColor Green

# Step 5: Get Bastion Resource ID
Write-Host "`nRetrieving Bastion information..." -ForegroundColor Yellow
$bastionResourceId = az network bastion show --name $BastionName --resource-group $ResourceGroupName --query "id" -o tsv 2>$null

if (-not $bastionResourceId) {
    Write-Host "✗ Failed to find Bastion: $BastionName in resource group: $ResourceGroupName" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Bastion found: $bastionResourceId" -ForegroundColor Green

# Step 6: Verify Bastion has native client support enabled
Write-Host "`nVerifying Bastion configuration..." -ForegroundColor Yellow
$bastionConfig = az network bastion show --name $BastionName --resource-group $ResourceGroupName --query "{enableTunneling:enableTunneling}" -o json 2>$null | ConvertFrom-Json

if ($bastionConfig.enableTunneling -ne $true) {
    Write-Host "⚠ Warning: Native client support (tunneling) may not be enabled on this Bastion" -ForegroundColor Yellow
    Write-Host "  To enable it, run: az network bastion update --name $BastionName --resource-group $ResourceGroupName --enable-tunneling true" -ForegroundColor Yellow
}

# Step 7: Connect to VM via RDP through Bastion
Write-Host "`n=== Initiating RDP Connection ===" -ForegroundColor Cyan
Write-Host "Connecting to VM via Azure Bastion native client..." -ForegroundColor Yellow

# Create a temporary RDP file with screen configuration
$rdpTempFile = Join-Path $env:TEMP "bastion_rdp_$(Get-Date -Format 'yyyyMMddHHmmss').rdp"

Write-Host "Creating RDP configuration file..." -ForegroundColor Yellow

# Build RDP file content
$rdpContent = @"
screen mode id:i:2
use multimon:i:$([int]$UseAllMonitors.IsPresent)
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
compression:i:1
keyboardhook:i:2
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
bandwidthautodetect:i:1
displayconnectionbar:i:1
enableworkspacereconnect:i:0
disable wallpaper:i:0
allow font smoothing:i:0
allow desktop composition:i:0
disable full window drag:i:1
disable menu anims:i:1
disable themes:i:0
disable cursor setting:i:0
bitmapcachepersistenable:i:1
full address:s:localhost:55000
audiomode:i:0
redirectprinters:i:1
redirectcomports:i:0
redirectsmartcards:i:1
redirectclipboard:i:1
redirectposdevices:i:0
autoreconnection enabled:i:1
authentication level:i:0
prompt for credentials:i:0
negotiate security layer:i:1
enablecredsspsupport:i:1
remoteapplicationmode:i:0
alternate shell:s:
shell working directory:s:
gatewayhostname:s:
gatewayusagemethod:i:4
gatewaycredentialssource:i:4
gatewayprofileusagemethod:i:0
promptcredentialonce:i:0
gatewaybrokeringtype:i:0
use redirection server name:i:0
rdgiskdcproxy:i:0
kdcproxyname:s:
"@

$rdpContent | Out-File -FilePath $rdpTempFile -Encoding ASCII -Force

$monitorMode = if ($UseAllMonitors.IsPresent) { "all monitors" } else { "single monitor" }
Write-Host "✓ RDP configured for: $monitorMode" -ForegroundColor Green
Write-Host "Note: This will open the native RDP client (mstsc.exe)`n" -ForegroundColor Gray

# Start the tunnel
Write-Host "Starting Bastion tunnel on port 55000..." -ForegroundColor Yellow

# Create a temporary script file to run the tunnel command
$tunnelScriptPath = Join-Path $env:TEMP "bastion_tunnel_$(Get-Date -Format 'yyyyMMddHHmmss').ps1"
$tunnelScript = @"
Write-Host 'Bastion tunnel starting...' -ForegroundColor Cyan
az network bastion tunnel ``
    --name '$BastionName' ``
    --resource-group '$ResourceGroupName' ``
    --target-resource-id '$vmResourceId' ``
    --resource-port 3389 ``
    --port 55000
"@
$tunnelScript | Out-File -FilePath $tunnelScriptPath -Encoding UTF8 -Force

# Start the tunnel process
$tunnelProcess = Start-Process "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$tunnelScriptPath`"" -PassThru -WindowStyle Normal

# Wait for the tunnel to establish (check if port 55000 is listening)
Write-Host "Waiting for tunnel to establish..." -ForegroundColor Yellow
$maxAttempts = 30
$attemptCount = 0
$tunnelReady = $false

while ($attemptCount -lt $maxAttempts -and -not $tunnelReady) {
    Start-Sleep -Seconds 1
    $attemptCount++
    
    # Check if port 55000 is listening
    $portCheck = Get-NetTCPConnection -LocalPort 55000 -State Listen -ErrorAction SilentlyContinue
    if ($portCheck) {
        $tunnelReady = $true
        Write-Host "✓ Bastion tunnel established on localhost:55000" -ForegroundColor Green
        # Give the tunnel a moment to stabilize
        Write-Host "Waiting for tunnel to stabilize..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        break
    }
    
    # Check if the process has exited (indicating an error)
    if ($tunnelProcess.HasExited) {
        Write-Host "`n✗ Tunnel process exited unexpectedly" -ForegroundColor Red
        Write-Host "Exit Code: $($tunnelProcess.ExitCode)" -ForegroundColor Red
        Write-Host "`nPossible causes:" -ForegroundColor Yellow
        Write-Host "  - Bastion tunneling feature may not be enabled" -ForegroundColor Gray
        Write-Host "  - Azure CLI authentication may have expired (try: az login)" -ForegroundColor Gray
        Write-Host "  - Insufficient permissions on Bastion or VM resources" -ForegroundColor Gray
        Write-Host "  - Port 55000 may already be in use" -ForegroundColor Gray
        
        if (Test-Path $rdpTempFile) {
            Remove-Item $rdpTempFile -Force
        }
        if (Test-Path $tunnelScriptPath) {
            Remove-Item $tunnelScriptPath -Force
        }
        exit 1
    }
    
    if ($attemptCount % 5 -eq 0) {
        Write-Host "  Still waiting... ($attemptCount seconds)" -ForegroundColor Gray
    }
}

if (-not $tunnelReady) {
    Write-Host "`n✗ Tunnel failed to establish within $maxAttempts seconds" -ForegroundColor Red
    Write-Host "The tunnel process is still running. Check the tunnel window for errors." -ForegroundColor Yellow
    
    # Cleanup
    if (-not $tunnelProcess.HasExited) {
        Stop-Process -Id $tunnelProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $rdpTempFile) {
        Remove-Item $rdpTempFile -Force
    }
    if (Test-Path $tunnelScriptPath) {
        Remove-Item $tunnelScriptPath -Force
    }
    exit 1
}

# Launch RDP client with the configuration file
Write-Host "Launching RDP client..." -ForegroundColor Yellow
Start-Process "mstsc.exe" -ArgumentList $rdpTempFile

Write-Host "`n✓ RDP client launched successfully" -ForegroundColor Green
Write-Host "`nThe Bastion tunnel will remain active. Close the tunnel PowerShell window when done." -ForegroundColor Cyan
Write-Host "Press Enter to cleanup temporary files and exit this script..." -ForegroundColor Yellow
Read-Host

# Cleanup
if (Test-Path $rdpTempFile) {
    Remove-Item $rdpTempFile -Force
}
if (Test-Path $tunnelScriptPath) {
    Remove-Item $tunnelScriptPath -Force
}

Write-Host "`n✓ Cleanup complete" -ForegroundColor Green
Write-Host "Note: The tunnel process is still running. Close its window to terminate the tunnel." -ForegroundColor Gray

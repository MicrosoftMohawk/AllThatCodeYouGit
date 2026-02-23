<#
.SYNOPSIS
    Connect to an Azure VM via RDP using Azure Bastion Native Client Support

.DESCRIPTION
    This script connects to an Azure VM through Azure Bastion using the native RDP client.
    Requires Azure CLI to be installed and Azure Bastion to have native client support enabled.

    When run without parameters, the script enters interactive mode and presents numbered
    selection menus to discover and choose Azure subscriptions, Bastion hosts, resource groups,
    and virtual machines. When parameters are provided on the command line, those prompts are
    skipped (full backward compatibility).

.PARAMETER VMName
    (Optional) The name of the Azure Virtual Machine to connect to.
    If omitted, the script lists available VMs and prompts for selection.

.PARAMETER ResourceGroupName
    (Optional) The name of the resource group containing the VM.
    If omitted, the script lists available resource groups and prompts for selection.

.PARAMETER BastionName
    (Optional) The name of the Azure Bastion resource.
    If omitted, the script lists available Bastion hosts across the subscription and prompts for selection.

.PARAMETER BastionResourceGroupName
    (Optional) The resource group containing the Azure Bastion resource, when it differs from
    the VM resource group. If omitted, defaults to the VM resource group (ResourceGroupName).
    Automatically populated when using interactive Bastion selection.

.PARAMETER SubscriptionId
    (Optional) The Azure subscription ID. If not provided, the script offers an interactive
    subscription picker or uses the current active subscription.

.PARAMETER UseAllMonitors
    (Optional) If specified, attempts to use all monitors. Note: The az network bastion rdp command
    uses default RDP settings and may not honor this parameter. Single monitor is typical default.

.EXAMPLE
    .\Connect-AzureVMBastion.ps1
    # Fully interactive mode — prompts for subscription, Bastion, resource group, and VM.

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion"
    # Direct connection with all parameters specified (no prompts).

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -ResourceGroupName "myRG"
    # Partial interactive mode — prompts for subscription, Bastion, and VM only.

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -BastionResourceGroupName "myNetworkRG"
    # Bastion is in a different resource group than the VM.

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -UseAllMonitors
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$BastionName,

    [Parameter(Mandatory = $false)]
    [string]$BastionResourceGroupName,

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

# Function to display a numbered selection menu and return the selected index (0-based)
function Show-SelectionMenu {
    param(
        [string]$Title,
        [string[]]$Items
    )

    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host "✗ No items found for: $Title" -ForegroundColor Red
        return $null
    }

    Write-Host "`n--- $Title ---" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Items[$i])" -ForegroundColor White
    }

    while ($true) {
        $input = Read-Host "`nEnter selection (1-$($Items.Count))"
        $index = 0
        if ([int]::TryParse($input, [ref]$index) -and $index -ge 1 -and $index -le $Items.Count) {
            return ($index - 1)
        }
        Write-Host "⚠ Invalid selection. Please enter a number between 1 and $($Items.Count)." -ForegroundColor Yellow
    }
}

# Function to interactively select an Azure subscription
function Select-Subscription {
    Write-Host "`nRetrieving available subscriptions..." -ForegroundColor Yellow
    $subscriptions = az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o json 2>$null | ConvertFrom-Json

    if (-not $subscriptions -or $subscriptions.Count -eq 0) {
        Write-Host "✗ No subscriptions found. Ensure you are logged in." -ForegroundColor Red
        return $null
    }

    $displayItems = @()
    foreach ($sub in $subscriptions) {
        $marker = if ($sub.isDefault) { " (current)" } else { "" }
        $displayItems += "$($sub.name) [$($sub.id)]$marker"
    }

    $selectedIndex = Show-SelectionMenu -Title "Select Azure Subscription" -Items $displayItems
    if ($null -eq $selectedIndex) { return $null }

    $selected = $subscriptions[$selectedIndex]
    Write-Host "✓ Selected subscription: $($selected.name)" -ForegroundColor Green

    az account set --subscription $selected.id 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Failed to set subscription" -ForegroundColor Red
        return $null
    }

    return $selected.id
}

# Function to interactively select a Bastion host (searches across all RGs in the subscription)
function Select-BastionHost {
    Write-Host "`nRetrieving available Bastion hosts..." -ForegroundColor Yellow
    $bastions = az network bastion list --query "[].{name:name, resourceGroup:resourceGroup}" -o json 2>$null | ConvertFrom-Json

    if (-not $bastions -or $bastions.Count -eq 0) {
        Write-Host "✗ No Bastion hosts found in the current subscription." -ForegroundColor Red
        Write-Host "  Ensure a Bastion resource exists and you have read permissions." -ForegroundColor Gray
        return $null
    }

    if ($bastions.Count -eq 1) {
        Write-Host "✓ Auto-selected the only Bastion host: $($bastions[0].name) (RG: $($bastions[0].resourceGroup))" -ForegroundColor Green
        return $bastions[0]
    }

    $displayItems = @()
    foreach ($b in $bastions) {
        $displayItems += "$($b.name)  (Resource Group: $($b.resourceGroup))"
    }

    $selectedIndex = Show-SelectionMenu -Title "Select Bastion Host" -Items $displayItems
    if ($null -eq $selectedIndex) { return $null }

    $selected = $bastions[$selectedIndex]
    Write-Host "✓ Selected Bastion: $($selected.name) (RG: $($selected.resourceGroup))" -ForegroundColor Green
    return $selected
}

# Function to interactively select a resource group
function Select-ResourceGroup {
    Write-Host "`nRetrieving available resource groups..." -ForegroundColor Yellow
    $resourceGroups = az group list --query "[].name" -o json 2>$null | ConvertFrom-Json

    if (-not $resourceGroups -or $resourceGroups.Count -eq 0) {
        Write-Host "✗ No resource groups found in the current subscription." -ForegroundColor Red
        return $null
    }

    $sorted = $resourceGroups | Sort-Object

    $selectedIndex = Show-SelectionMenu -Title "Select VM Resource Group" -Items $sorted
    if ($null -eq $selectedIndex) { return $null }

    $selected = $sorted[$selectedIndex]
    Write-Host "✓ Selected resource group: $selected" -ForegroundColor Green
    return $selected
}

# Function to interactively select a virtual machine
function Select-VirtualMachine {
    param(
        [string]$RGName
    )

    if ($RGName) {
        Write-Host "`nRetrieving VMs in resource group: $RGName..." -ForegroundColor Yellow
        $vms = az vm list --resource-group $RGName --query "[].name" -o json 2>$null | ConvertFrom-Json
    } else {
        Write-Host "`nRetrieving VMs across the subscription..." -ForegroundColor Yellow
        $vms = az vm list --query "[].{name:name, resourceGroup:resourceGroup}" -o json 2>$null | ConvertFrom-Json
    }

    if (-not $vms -or $vms.Count -eq 0) {
        $scope = if ($RGName) { "resource group '$RGName'" } else { "the current subscription" }
        Write-Host "✗ No virtual machines found in $scope." -ForegroundColor Red
        return $null
    }

    if ($RGName) {
        $sorted = $vms | Sort-Object
        $selectedIndex = Show-SelectionMenu -Title "Select Virtual Machine" -Items $sorted
        if ($null -eq $selectedIndex) { return $null }

        $selected = $sorted[$selectedIndex]
        Write-Host "✓ Selected VM: $selected" -ForegroundColor Green
        return @{ Name = $selected; ResourceGroup = $RGName }
    } else {
        $displayItems = @()
        foreach ($vm in $vms) {
            $displayItems += "$($vm.name)  (Resource Group: $($vm.resourceGroup))"
        }

        $selectedIndex = Show-SelectionMenu -Title "Select Virtual Machine" -Items $displayItems
        if ($null -eq $selectedIndex) { return $null }

        $selected = $vms[$selectedIndex]
        Write-Host "✓ Selected VM: $($selected.name) (RG: $($selected.resourceGroup))" -ForegroundColor Green
        return @{ Name = $selected.name; ResourceGroup = $selected.resourceGroup }
    }
}

# Main script execution
Write-Host "`n=== Azure Bastion RDP Connection Script ===" -ForegroundColor Cyan

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

# Step 3: Subscription selection
if ($SubscriptionId) {
    Write-Host "`nSetting subscription to: $SubscriptionId" -ForegroundColor Yellow
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Failed to set subscription" -ForegroundColor Red
        exit 1
    }
} else {
    $selectedSubId = Select-Subscription
    if (-not $selectedSubId) {
        Write-Host "✗ Subscription selection is required to continue." -ForegroundColor Red
        exit 1
    }
    $SubscriptionId = $selectedSubId
}

# Step 4: Bastion host selection
if (-not $BastionName) {
    $bastionSelection = Select-BastionHost
    if (-not $bastionSelection) {
        exit 1
    }
    $BastionName = $bastionSelection.name
    $BastionResourceGroupName = $bastionSelection.resourceGroup
}

# Step 5: VM Resource Group selection
if (-not $ResourceGroupName) {
    $ResourceGroupName = Select-ResourceGroup
    if (-not $ResourceGroupName) {
        exit 1
    }
}

# Step 6: VM selection
if (-not $VMName) {
    $vmSelection = Select-VirtualMachine -RGName $ResourceGroupName
    if (-not $vmSelection) {
        exit 1
    }
    $VMName = $vmSelection.Name
    $ResourceGroupName = $vmSelection.ResourceGroup
}

# Resolve the Bastion resource group (may differ from VM resource group)
$bastionRG = if ($BastionResourceGroupName) { $BastionResourceGroupName } else { $ResourceGroupName }

# Display resolved connection summary
Write-Host "`n=== Connection Summary ===" -ForegroundColor Cyan
Write-Host "Target VM:         $VMName" -ForegroundColor White
Write-Host "VM Resource Group:  $ResourceGroupName" -ForegroundColor White
Write-Host "Bastion:           $BastionName" -ForegroundColor White
Write-Host "Bastion RG:        $bastionRG`n" -ForegroundColor White

# Step 7: Get VM Resource ID
Write-Host "`nRetrieving VM information..." -ForegroundColor Yellow
$vmResourceId = az vm show --name $VMName --resource-group $ResourceGroupName --query "id" -o tsv 2>$null

if (-not $vmResourceId) {
    Write-Host "✗ Failed to find VM: $VMName in resource group: $ResourceGroupName" -ForegroundColor Red
    exit 1
}

Write-Host "✓ VM found: $vmResourceId" -ForegroundColor Green

# Step 8: Get Bastion Resource ID
Write-Host "`nRetrieving Bastion information..." -ForegroundColor Yellow
$bastionResourceId = az network bastion show --name $BastionName --resource-group $bastionRG --query "id" -o tsv 2>$null

if (-not $bastionResourceId) {
    Write-Host "✗ Failed to find Bastion: $BastionName in resource group: $bastionRG" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Bastion found: $bastionResourceId" -ForegroundColor Green

# Step 9: Verify Bastion has native client support enabled
Write-Host "`nVerifying Bastion configuration..." -ForegroundColor Yellow
$bastionConfig = az network bastion show --name $BastionName --resource-group $bastionRG --query "{enableTunneling:enableTunneling}" -o json 2>$null | ConvertFrom-Json

if ($bastionConfig.enableTunneling -ne $true) {
    Write-Host "⚠ Warning: Native client support (tunneling) may not be enabled on this Bastion" -ForegroundColor Yellow
    Write-Host "  To enable it, run: az network bastion update --name $BastionName --resource-group $bastionRG --enable-tunneling true" -ForegroundColor Yellow
}

# Step 10: Connect to VM via RDP through Bastion
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
    --resource-group '$bastionRG' ``
    --target-resource-id '$vmResourceId' ``
    --resource-port 3389 ``
    --port 55000
"@
$tunnelScript | Out-File -FilePath $tunnelScriptPath -Encoding UTF8 -Force

# Start the tunnel process
$tunnelProcess = Start-Process "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$tunnelScriptPath`"" -PassThru -WindowStyle Normal

# Wait for the tunnel to establish (check if port 55000 is listening)
Write-Host "Waiting for tunnel to establish..." -ForegroundColor Yellow
$maxAttempts = 60
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

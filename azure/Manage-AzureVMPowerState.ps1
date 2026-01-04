#Requires -Modules Az.Accounts, Az.Compute
<#
.SYNOPSIS
    Manages Azure VM power state (on/off) across Commercial and Government cloud environments.

.DESCRIPTION
    This script provides an interactive way to:
    - Select Azure cloud environment (Commercial or Government)
    - Authenticate to the selected environment
    - Select a subscription
    - Select a resource group
    - Select a virtual machine
    - Power on or power off the selected VM

.EXAMPLE
    .\Manage-AzureVMPowerState.ps1

.NOTES
    Requires: Az.Accounts and Az.Compute modules
    Install-Module -Name Az.Accounts -Force
    Install-Module -Name Az.Compute -Force
#>

function Get-CurrentAzureContext {
    <#
    .SYNOPSIS
        Checks if user is currently logged into Azure and returns context info
    #>
    try {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if ($context) {
            return $context
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-EnvironmentDisplayName {
    <#
    .SYNOPSIS
        Converts environment name to display name
    #>
    param(
        [string]$EnvironmentName
    )
    
    switch ($EnvironmentName) {
        "AzureCloud" { return "Azure Commercial (Public Cloud)" }
        "AzureUSGovernment" { return "Azure Government" }
        default { return $EnvironmentName }
    }
}

function Select-AzureEnvironment {
    <#
    .SYNOPSIS
        Checks current Azure context and prompts user to continue or select new environment
    #>
    $currentContext = Get-CurrentAzureContext
    
    if ($currentContext) {
        Write-Host "`n=== Current Azure Login ===" -ForegroundColor Cyan
        Write-Host "You are currently logged in to: $(Get-EnvironmentDisplayName -EnvironmentName $currentContext.Environment.Name)" -ForegroundColor Green
        Write-Host "Account: $($currentContext.Account.Id)" -ForegroundColor Green
        Write-Host "Subscription: $($currentContext.Subscription.Name)" -ForegroundColor Green
        
        Write-Host "`n1. Continue with current login" -ForegroundColor Yellow
        Write-Host "2. Switch to Azure Commercial (Public Cloud)" -ForegroundColor Yellow
        Write-Host "3. Switch to Azure Government" -ForegroundColor Yellow
        
        $choice = Read-Host "Select option (1, 2, or 3)"
        
        switch ($choice) {
            "1" {
                Write-Host "Continuing with current login..." -ForegroundColor Green
                return $currentContext.Environment.Name
            }
            "2" {
                Write-Host "Selected: Azure Commercial" -ForegroundColor Green
                return "AzureCloud"
            }
            "3" {
                Write-Host "Selected: Azure Government" -ForegroundColor Green
                return "AzureUSGovernment"
            }
            default {
                Write-Host "Invalid selection. Using current login." -ForegroundColor Yellow
                return $currentContext.Environment.Name
            }
        }
    }
    else {
        Write-Host "`n=== Azure Cloud Environment Selection ===" -ForegroundColor Cyan
        Write-Host "You are not currently logged into Azure." -ForegroundColor Yellow
        Write-Host "`n1. Azure Commercial (Public Cloud)" -ForegroundColor Yellow
        Write-Host "2. Azure Government" -ForegroundColor Yellow
        
        $choice = Read-Host "Select environment (1 or 2)"
        
        switch ($choice) {
            "1" {
                Write-Host "Selected: Azure Commercial" -ForegroundColor Green
                return "AzureCloud"
            }
            "2" {
                Write-Host "Selected: Azure Government" -ForegroundColor Green
                return "AzureUSGovernment"
            }
            default {
                Write-Host "Invalid selection. Defaulting to Azure Commercial." -ForegroundColor Yellow
                return "AzureCloud"
            }
        }
    }
}

function Connect-ToAzure {
    <#
    .SYNOPSIS
        Connects to Azure with specified environment
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment
    )
    
    try {
        $currentContext = Get-AzContext -ErrorAction SilentlyContinue
        
        # If already logged in to the same environment, skip connection
        if ($currentContext -and $currentContext.Environment.Name -eq $Environment) {
            Write-Host "Already logged into $(Get-EnvironmentDisplayName -EnvironmentName $Environment)" -ForegroundColor Green
            return
        }
        
        # If logged in to different environment, disconnect first
        if ($currentContext -and $currentContext.Environment.Name -ne $Environment) {
            Write-Host "Disconnecting from current environment..." -ForegroundColor Yellow
            Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
        }
        
        Write-Host "`nConnecting to $(Get-EnvironmentDisplayName -EnvironmentName $Environment)..." -ForegroundColor Cyan
        Connect-AzAccount -Environment $Environment -ErrorAction Stop
        Write-Host "Successfully connected to Azure" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to connect to Azure: $_" -ForegroundColor Red
        exit
    }
}

function Select-Subscription {
    <#
    .SYNOPSIS
        Prompts user to select Azure subscription
    #>
    try {
        Write-Host "`n=== Subscription Selection ===" -ForegroundColor Cyan
        
        $subscriptions = Get-AzSubscription -ErrorAction Stop | Sort-Object Name
        
        if ($subscriptions.Count -eq 0) {
            Write-Host "No subscriptions found." -ForegroundColor Red
            exit
        }
        
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host "$($i + 1). $($subscriptions[$i].Name) (ID: $($subscriptions[$i].Id.Split('/')[-1]))" -ForegroundColor Yellow
        }
        
        $selection = Read-Host "Select subscription (enter number)"
        
        if ($selection -match "^\d+$" -and $selection -gt 0 -and $selection -le $subscriptions.Count) {
            $selected = $subscriptions[$selection - 1]
            Set-AzContext -SubscriptionObject $selected -ErrorAction Stop | Out-Null
            Write-Host "Selected subscription: $($selected.Name)" -ForegroundColor Green
            return $selected
        }
        else {
            Write-Host "Invalid selection." -ForegroundColor Red
            exit
        }
    }
    catch {
        Write-Host "Failed to retrieve subscriptions: $_" -ForegroundColor Red
        exit
    }
}

function Select-ResourceGroup {
    <#
    .SYNOPSIS
        Prompts user to select resource group
    #>
    try {
        Write-Host "`n=== Resource Group Selection ===" -ForegroundColor Cyan
        
        $resourceGroups = Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName
        
        if ($resourceGroups.Count -eq 0) {
            Write-Host "No resource groups found in this subscription." -ForegroundColor Red
            exit
        }
        
        for ($i = 0; $i -lt $resourceGroups.Count; $i++) {
            Write-Host "$($i + 1). $($resourceGroups[$i].ResourceGroupName) (Location: $($resourceGroups[$i].Location))" -ForegroundColor Yellow
        }
        
        $selection = Read-Host "Select resource group (enter number)"
        
        if ($selection -match "^\d+$" -and $selection -gt 0 -and $selection -le $resourceGroups.Count) {
            $selected = $resourceGroups[$selection - 1]
            Write-Host "Selected resource group: $($selected.ResourceGroupName)" -ForegroundColor Green
            return $selected.ResourceGroupName
        }
        else {
            Write-Host "Invalid selection." -ForegroundColor Red
            exit
        }
    }
    catch {
        Write-Host "Failed to retrieve resource groups: $_" -ForegroundColor Red
        exit
    }
}

function Select-VirtualMachine {
    <#
    .SYNOPSIS
        Prompts user to select virtual machine
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )
    
    try {
        Write-Host "`n=== Virtual Machine Selection ===" -ForegroundColor Cyan
        
        $vms = Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Sort-Object Name
        
        if ($vms.Count -eq 0) {
            Write-Host "No virtual machines found in this resource group." -ForegroundColor Red
            exit
        }
        
        for ($i = 0; $i -lt $vms.Count; $i++) {
            Write-Host "$($i + 1). $($vms[$i].Name)" -ForegroundColor Yellow
        }
        
        $selection = Read-Host "Select virtual machine (enter number)"
        
        if ($selection -match "^\d+$" -and $selection -gt 0 -and $selection -le $vms.Count) {
            $selected = $vms[$selection - 1]
            Write-Host "Selected VM: $($selected.Name)" -ForegroundColor Green
            return $selected
        }
        else {
            Write-Host "Invalid selection." -ForegroundColor Red
            exit
        }
    }
    catch {
        Write-Host "Failed to retrieve virtual machines: $_" -ForegroundColor Red
        exit
    }
}

function Select-PowerAction {
    <#
    .SYNOPSIS
        Prompts user to select power action
    #>
    Write-Host "`n=== Power Action Selection ===" -ForegroundColor Cyan
    Write-Host "1. Power On" -ForegroundColor Yellow
    Write-Host "2. Power Off" -ForegroundColor Yellow
    Write-Host "3. Restart" -ForegroundColor Yellow
    
    $choice = Read-Host "Select action (1, 2, or 3)"
    
    switch ($choice) {
        "1" { return "PowerOn" }
        "2" { return "PowerOff" }
        "3" { return "Restart" }
        default {
            Write-Host "Invalid selection." -ForegroundColor Red
            exit
        }
    }
}

function Invoke-VMPowerAction {
    <#
    .SYNOPSIS
        Executes the power action on the VM
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$VM,
        [Parameter(Mandatory = $true)]
        [string]$Action
    )
    
    try {
        Write-Host "`nExecuting $Action on VM: $($VM.Name)..." -ForegroundColor Cyan
        
        switch ($Action) {
            "PowerOn" {
                Start-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -ErrorAction Stop -NoWait | Out-Null
                Write-Host "VM Power On initiated successfully." -ForegroundColor Green
            }
            "PowerOff" {
                Stop-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Force -ErrorAction Stop -NoWait | Out-Null
                Write-Host "VM Power Off initiated successfully." -ForegroundColor Green
            }
            "Restart" {
                Restart-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -ErrorAction Stop -NoWait | Out-Null
                Write-Host "VM Restart initiated successfully." -ForegroundColor Green
            }
        }
        
        Write-Host "Note: Operations run asynchronously. VM may take a few moments to complete the action." -ForegroundColor Yellow
    }
    catch {
        Write-Host "Failed to execute $Action : $_" -ForegroundColor Red
        exit
    }
}

function Get-VMStatus {
    <#
    .SYNOPSIS
        Retrieves and displays current VM status
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$VM
    )
    
    try {
        $status = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status -ErrorAction Stop
        $powerState = $status.Statuses | Where-Object { $_.Code -match "PowerState" }
        
        Write-Host "`nCurrent VM Status:" -ForegroundColor Cyan
        Write-Host "VM Name: $($VM.Name)" -ForegroundColor White
        Write-Host "Resource Group: $($VM.ResourceGroupName)" -ForegroundColor White
        if ($powerState) {
            Write-Host "Power State: $($powerState.DisplayStatus)" -ForegroundColor White
        }
    }
    catch {
        Write-Host "Failed to retrieve VM status: $_" -ForegroundColor Red
    }
}

# Main Script
function Main {
    Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Azure VM Power State Manager          ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
    
    # Step 1: Select Environment
    $environment = Select-AzureEnvironment
    
    # Step 2: Connect to Azure
    Connect-ToAzure -Environment $environment
    
    # Step 3: Select Subscription
    $subscription = Select-Subscription
    
    # Step 4: Select Resource Group
    $resourceGroup = Select-ResourceGroup
    
    # Step 5: Select Virtual Machine
    $vm = Select-VirtualMachine -ResourceGroupName $resourceGroup
    
    # Step 6: Display Current Status
    Get-VMStatus -VM $vm
    
    # Step 7: Select Power Action
    $action = Select-PowerAction
    
    # Step 8: Execute Action
    Invoke-VMPowerAction -VM $vm -Action $action
    
    Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Operation Complete                    ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
}

# Run Main Script
Main

# ============================================================================
# Policy Exemption Management Script for Custom Compliance Initiatives
# Purpose: Create, list, report on, and clean up policy exemptions for
#          custom initiatives deployed by Deploy-CustomNIST-Initiative.ps1
# ============================================================================
# Works with the ARM-format custom_initiative.json that wraps data inside a
# "properties" container (policyType: Custom).
# ============================================================================

<#
.SYNOPSIS
    Helper functions and interactive workflows for managing Azure Policy exemptions
    on custom compliance initiatives deployed by Deploy-CustomNIST-Initiative.ps1.

.DESCRIPTION
    This script:
    1. Authenticates to Azure (or reuses existing session)
    2. Auto-discovers the custom initiative assignment (or prompts for it)
    3. Loads policy reference IDs from custom_initiative.json
    4. Provides helper functions and interactive examples for:
       - Creating exemptions (full scope or specific policies)
       - Generating exemption reports
       - Removing expired exemptions
       - Discovering policy reference IDs

.PARAMETER SubscriptionId
    Azure Subscription ID. If omitted, the script prompts interactively.

.PARAMETER ManagementGroupId
    Management Group scope. If provided, exemptions target this scope.

.PARAMETER AssignmentName
    Name of the policy assignment to manage exemptions for.
    If omitted, the script lists assignments and prompts for selection.

.PARAMETER JsonPath
    Path to directory containing custom_initiative.json.
    Defaults to the same directory as this script.

.EXAMPLE
    .\Manage-PolicyExemptions.ps1
    # Interactive mode: discovers assignments, prompts for selection

.EXAMPLE
    .\Manage-PolicyExemptions.ps1 -AssignmentName "NIST-SP-800-53-Rev-5-Custom" -SubscriptionId "abc-123"

.NOTES
    Requires: Az.Resources module
    Companion to: Deploy-CustomNIST-Initiative.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ManagementGroupId,

    [Parameter()]
    [string]$AssignmentName,

    [Parameter()]
    [string]$JsonPath
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

#region Helper Functions

function Get-InitiativePolicyReferences {
    <#
    .SYNOPSIS
        Reads custom_initiative.json and returns all policy definition reference IDs.
        Handles ARM format with properties wrapper.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$JsonFilePath
    )

    if (-not (Test-Path $JsonFilePath)) {
        Write-Host "  WARNING: Custom initiative JSON not found: $JsonFilePath" -ForegroundColor Yellow
        Write-Host "  Run Deploy-CustomNIST-Initiative.ps1 first to generate it." -ForegroundColor Yellow
        return @()
    }

    $json = Get-Content $JsonFilePath -Raw | ConvertFrom-Json
    $props = if ($json.properties) { $json.properties } else { $json }

    if (-not $props.policyDefinitions) {
        Write-Host "  WARNING: No policyDefinitions found in JSON." -ForegroundColor Yellow
        return @()
    }

    return @($props.policyDefinitions)
}

function Find-PolicyReferenceIds {
    <#
    .SYNOPSIS
        Searches policy definitions in the custom initiative by keyword.
    .PARAMETER PolicyDefinitions
        Array of policy definition objects from the initiative JSON.
    .PARAMETER SearchTerm
        Text to search for in policyDefinitionId or policyDefinitionReferenceId.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$PolicyDefinitions,

        [Parameter(Mandatory)]
        [string]$SearchTerm
    )

    $matches = @($PolicyDefinitions | Where-Object {
        ($_.policyDefinitionId -match "(?i)$SearchTerm") -or
        ($_.policyDefinitionReferenceId -match "(?i)$SearchTerm")
    })

    return $matches
}

function New-PolicyExemptionForResourceGroup {
    <#
    .SYNOPSIS
        Creates a policy exemption for an entire resource group.
    .PARAMETER ResourceGroupName
        Name of the resource group to exempt.
    .PARAMETER ExemptionName
        Unique name for the exemption.
    .PARAMETER ExemptionCategory
        Waiver or Mitigated.
    .PARAMETER ExpirationMonths
        Number of months until exemption expires (default: 6).
    .PARAMETER Reason
        Business justification for the exemption.
    .PARAMETER Assignment
        Policy assignment object.
    .PARAMETER Scope
        Base scope (subscription or management group path).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$ExemptionName,

        [Parameter()]
        [ValidateSet("Waiver", "Mitigated")]
        [string]$ExemptionCategory = "Waiver",

        [Parameter()]
        [int]$ExpirationMonths = 6,

        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter(Mandatory)]
        [PSObject]$Assignment,

        [Parameter(Mandatory)]
        [string]$Scope
    )

    $rgScope = "$Scope/resourceGroups/$ResourceGroupName"

    $exemptionParams = @{
        Name              = $ExemptionName
        DisplayName       = "$ResourceGroupName - $ExemptionCategory"
        Description       = $Reason
        Scope             = $rgScope
        PolicyAssignment  = $Assignment
        ExemptionCategory = $ExemptionCategory
        ExpiresOn         = (Get-Date).AddMonths($ExpirationMonths)
        Metadata          = (@{
            "CreatedBy"     = $env:USERNAME
            "CreatedDate"   = (Get-Date).ToString("yyyy-MM-dd")
            "Justification" = $Reason
        } | ConvertTo-Json)
    }

    if ($PSCmdlet.ShouldProcess($rgScope, "Create policy exemption '$ExemptionName'")) {
        $result = New-AzPolicyExemption @exemptionParams
        Write-Host "  Exemption created for resource group: $ResourceGroupName" -ForegroundColor Green
        Write-Host "  Exemption ID: $($result.ResourceId)" -ForegroundColor Gray
        return $result
    }
}

function New-PolicyExemptionForSpecificPolicies {
    <#
    .SYNOPSIS
        Creates an exemption for specific policies within the initiative.
    .PARAMETER Scope
        Full scope path (subscription, resource group, or resource).
    .PARAMETER PolicyReferenceIds
        Array of policy definition reference IDs to exempt (GUIDs from initiative).
    .PARAMETER ExemptionName
        Unique name for the exemption.
    .PARAMETER ExemptionCategory
        Waiver or Mitigated.
    .PARAMETER Reason
        Business justification.
    .PARAMETER ExpirationMonths
        Number of months until exemption expires (default: 6).
    .PARAMETER Assignment
        Policy assignment object.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string[]]$PolicyReferenceIds,

        [Parameter(Mandatory)]
        [string]$ExemptionName,

        [Parameter()]
        [ValidateSet("Waiver", "Mitigated")]
        [string]$ExemptionCategory = "Waiver",

        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter()]
        [int]$ExpirationMonths = 6,

        [Parameter(Mandatory)]
        [PSObject]$Assignment
    )

    $exemptionParams = @{
        Name                         = $ExemptionName
        DisplayName                  = "Selective Policy Exemption"
        Description                  = $Reason
        Scope                        = $Scope
        PolicyAssignment             = $Assignment
        PolicyDefinitionReferenceId  = $PolicyReferenceIds
        ExemptionCategory            = $ExemptionCategory
        ExpiresOn                    = (Get-Date).AddMonths($ExpirationMonths)
    }

    if ($PSCmdlet.ShouldProcess($Scope, "Create policy exemption '$ExemptionName' for $($PolicyReferenceIds.Count) policies")) {
        $result = New-AzPolicyExemption @exemptionParams
        Write-Host "  Exemption created for $($PolicyReferenceIds.Count) policies at scope: $Scope" -ForegroundColor Green
        Write-Host "  Exemption ID: $($result.ResourceId)" -ForegroundColor Gray
        return $result
    }
}

function Get-ExemptionReport {
    <#
    .SYNOPSIS
        Generates a report of all current exemptions at a given scope.
    .PARAMETER Scope
        Scope to query (subscription or management group path).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Scope
    )

    $exemptions = Get-AzPolicyExemption -Scope $Scope -ErrorAction SilentlyContinue

    if (-not $exemptions -or $exemptions.Count -eq 0) {
        Write-Host "  No exemptions found at scope: $Scope" -ForegroundColor Yellow
        return @()
    }

    $report = $exemptions | Select-Object `
        Name,
        @{Name = "DisplayName"; Expression = { $_.Properties.DisplayName } },
        @{Name = "Category"; Expression = { $_.Properties.ExemptionCategory } },
        @{Name = "ExpiresOn"; Expression = { $_.Properties.ExpiresOn } },
        @{Name = "AssignmentId"; Expression = { $_.Properties.PolicyAssignmentId } },
        @{Name = "ExemptedPolicies"; Expression = {
            if ($_.Properties.PolicyDefinitionReferenceIds) {
                ($_.Properties.PolicyDefinitionReferenceIds -join ", ")
            } else { "(all policies)" }
        }},
        @{Name = "Status"; Expression = {
            if ($_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date)) {
                "EXPIRED"
            }
            elseif ($_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date).AddDays(30)) {
                "EXPIRING SOON"
            }
            else {
                "ACTIVE"
            }
        }}

    return $report
}

function Remove-ExpiredExemptions {
    <#
    .SYNOPSIS
        Finds and removes all expired exemptions at a given scope.
    .PARAMETER Scope
        Scope to query.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Scope
    )

    $exemptions = Get-AzPolicyExemption -Scope $Scope -ErrorAction SilentlyContinue
    $expired = @($exemptions | Where-Object {
        $_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date)
    })

    if ($expired.Count -eq 0) {
        Write-Host "  No expired exemptions found." -ForegroundColor Green
        return
    }

    Write-Host "  Found $($expired.Count) expired exemption(s)." -ForegroundColor Yellow

    foreach ($exemption in $expired) {
        if ($PSCmdlet.ShouldProcess($exemption.Name, "Remove expired exemption (expired: $($exemption.Properties.ExpiresOn))")) {
            Remove-AzPolicyExemption -Id $exemption.ResourceId -Force
            Write-Host "  Removed: $($exemption.Name)" -ForegroundColor Green
        }
    }
}

#endregion

# ============================================================================
# MAIN SCRIPT
# ============================================================================

$ErrorActionPreference = 'Stop'

#region Authentication & Context
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host " Policy Exemption Management" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Check for Az module
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Host "  ERROR: Az.Resources module required. Install with:" -ForegroundColor Red
    Write-Host "  Install-Module Az -Scope CurrentUser" -ForegroundColor Cyan
    exit 1
}

# Check Azure connection
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host "  Not connected to Azure. Launching login..." -ForegroundColor Yellow
    Connect-AzAccount
    $context = Get-AzContext
}
Write-Host "  Connected as: $($context.Account.Id)" -ForegroundColor Green

# Select subscription
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptions = @(Get-AzSubscription -ErrorAction Stop)
    if ($subscriptions.Count -eq 0) {
        Write-Host "  ERROR: No accessible subscriptions." -ForegroundColor Red
        exit 1
    }
    elseif ($subscriptions.Count -eq 1) {
        $SubscriptionId = $subscriptions[0].Id
        Write-Host "  Using subscription: $($subscriptions[0].Name) ($SubscriptionId)" -ForegroundColor Green
    }
    else {
        Write-Host "`n  Available subscriptions:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            $marker = if ($subscriptions[$i].Id -eq $context.Subscription.Id) { " (current)" } else { "" }
            Write-Host "    [$i] $($subscriptions[$i].Name) - $($subscriptions[$i].Id)$marker"
        }
        do {
            $subInput = Read-Host "`n  Select subscription (0-$($subscriptions.Count - 1))"
            $subIdx = $null
            $valid = [int]::TryParse($subInput, [ref]$subIdx) -and ($subIdx -ge 0) -and ($subIdx -lt $subscriptions.Count)
        } while (-not $valid)
        $SubscriptionId = $subscriptions[$subIdx].Id
    }
}
Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
Write-Host "  Context set to subscription: $SubscriptionId" -ForegroundColor Gray

# Determine scope
if ($ManagementGroupId) {
    $baseScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
    Write-Host "  Scope: Management Group - $ManagementGroupId" -ForegroundColor Green
} else {
    $baseScope = "/subscriptions/$SubscriptionId"
    Write-Host "  Scope: Subscription - $SubscriptionId" -ForegroundColor Green
}
#endregion

#region Discover Assignment
Write-Host "`nDiscovering policy assignments..." -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($AssignmentName)) {
    # List assignments at scope and let user pick
    $assignments = @(Get-AzPolicyAssignment -Scope $baseScope -ErrorAction SilentlyContinue)

    # Filter to initiative assignments (policy set definitions)
    $setAssignments = @($assignments | Where-Object {
        $_.Properties.PolicyDefinitionId -match 'policySetDefinitions/'
    })

    if ($setAssignments.Count -eq 0) {
        Write-Host "  No initiative assignments found at scope: $baseScope" -ForegroundColor Yellow
        Write-Host "  Run Deploy-CustomNIST-Initiative.ps1 first to create and assign an initiative." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "  Found $($setAssignments.Count) initiative assignment(s):" -ForegroundColor Green
    for ($i = 0; $i -lt $setAssignments.Count; $i++) {
        $dn = $setAssignments[$i].Properties.DisplayName
        if (-not $dn) { $dn = $setAssignments[$i].Name }
        Write-Host "    [$i] $dn ($($setAssignments[$i].Name))" -ForegroundColor Cyan
    }

    do {
        $assignInput = Read-Host "`n  Select assignment (0-$($setAssignments.Count - 1))"
        $assignIdx = $null
        $valid = [int]::TryParse($assignInput, [ref]$assignIdx) -and ($assignIdx -ge 0) -and ($assignIdx -lt $setAssignments.Count)
    } while (-not $valid)

    $selectedAssignment = $setAssignments[$assignIdx]
    $AssignmentName = $selectedAssignment.Name
} else {
    $selectedAssignment = Get-AzPolicyAssignment -Name $AssignmentName -Scope $baseScope -ErrorAction Stop
}

Write-Host "  Using assignment: $AssignmentName" -ForegroundColor Green
Write-Host "  Assignment ID: $($selectedAssignment.ResourceId)" -ForegroundColor Gray
#endregion

#region Load Policy References from JSON
if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    $JsonPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
$customJsonFile = Join-Path $JsonPath "custom_initiative.json"

$policyDefs = Get-InitiativePolicyReferences -JsonFilePath $customJsonFile
if ($policyDefs.Count -gt 0) {
    Write-Host "  Loaded $($policyDefs.Count) policy definitions from custom_initiative.json" -ForegroundColor Green
} else {
    Write-Host "  Could not load policy definitions. Some functions may be limited." -ForegroundColor Yellow
}
#endregion

#region Interactive Menu
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host " What would you like to do?" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  [1] Create exemption for a resource group" -ForegroundColor White
Write-Host "  [2] Create exemption for specific policies" -ForegroundColor White
Write-Host "  [3] Generate exemption report" -ForegroundColor White
Write-Host "  [4] Remove expired exemptions" -ForegroundColor White
Write-Host "  [5] Search policy reference IDs" -ForegroundColor White
Write-Host "  [6] List all policy reference IDs" -ForegroundColor White
Write-Host "  [Q] Quit" -ForegroundColor White

$menuChoice = Read-Host "`n  Enter choice"

switch ($menuChoice.ToUpper()) {
    '1' {
        # Create exemption for a resource group
        Write-Host "`n  Create Resource Group Exemption" -ForegroundColor Cyan
        $rgName = Read-Host "  Resource group name"
        $exemptName = Read-Host "  Exemption name (unique)"
        $reason = Read-Host "  Business justification"

        Write-Host "  Category: [1] Waiver  [2] Mitigated" -ForegroundColor Gray
        $catChoice = Read-Host "  Category (1 or 2)"
        $category = if ($catChoice -eq "2") { "Mitigated" } else { "Waiver" }

        $monthsInput = Read-Host "  Expiration months (default: 6)"
        $months = if ([string]::IsNullOrWhiteSpace($monthsInput)) { 6 } else { [int]$monthsInput }

        New-PolicyExemptionForResourceGroup `
            -ResourceGroupName $rgName `
            -ExemptionName $exemptName `
            -ExemptionCategory $category `
            -ExpirationMonths $months `
            -Reason $reason `
            -Assignment $selectedAssignment `
            -Scope $baseScope
    }
    '2' {
        # Create exemption for specific policies
        Write-Host "`n  Create Specific Policy Exemption" -ForegroundColor Cyan

        if ($policyDefs.Count -gt 0) {
            Write-Host "  Search for policies to exempt (or type 'list' to see all):" -ForegroundColor Gray
            $search = Read-Host "  Search term"

            if ($search -eq 'list') {
                for ($i = 0; $i -lt [Math]::Min($policyDefs.Count, 50); $i++) {
                    $refId = $policyDefs[$i].policyDefinitionReferenceId
                    $defId = $policyDefs[$i].policyDefinitionId.Split('/')[-1]
                    Write-Host "    [$i] $refId ($defId)"
                }
                if ($policyDefs.Count -gt 50) {
                    Write-Host "    ... and $($policyDefs.Count - 50) more. Use search to narrow." -ForegroundColor Gray
                }
            } else {
                $found = Find-PolicyReferenceIds -PolicyDefinitions $policyDefs -SearchTerm $search
                if ($found.Count -eq 0) {
                    Write-Host "  No matches found for '$search'." -ForegroundColor Yellow
                } else {
                    Write-Host "  Found $($found.Count) matching policies:" -ForegroundColor Green
                    for ($i = 0; $i -lt $found.Count; $i++) {
                        Write-Host "    [$i] $($found[$i].policyDefinitionReferenceId)" -ForegroundColor Cyan
                    }
                }
            }
        }

        Write-Host "`n  Enter policy reference IDs to exempt (comma-separated):" -ForegroundColor Gray
        $refIdsInput = Read-Host "  Reference IDs"
        $refIds = @($refIdsInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        if ($refIds.Count -eq 0) {
            Write-Host "  No reference IDs provided. Aborting." -ForegroundColor Yellow
        } else {
            $scopeInput = Read-Host "  Target scope (press Enter for base scope: $baseScope)"
            $targetScope = if ([string]::IsNullOrWhiteSpace($scopeInput)) { $baseScope } else { $scopeInput }

            $exemptName = Read-Host "  Exemption name (unique)"
            $reason = Read-Host "  Business justification"

            Write-Host "  Category: [1] Waiver  [2] Mitigated" -ForegroundColor Gray
            $catChoice = Read-Host "  Category (1 or 2)"
            $category = if ($catChoice -eq "2") { "Mitigated" } else { "Waiver" }

            $monthsInput = Read-Host "  Expiration months (default: 6)"
            $months = if ([string]::IsNullOrWhiteSpace($monthsInput)) { 6 } else { [int]$monthsInput }

            New-PolicyExemptionForSpecificPolicies `
                -Scope $targetScope `
                -PolicyReferenceIds $refIds `
                -ExemptionName $exemptName `
                -ExemptionCategory $category `
                -Reason $reason `
                -ExpirationMonths $months `
                -Assignment $selectedAssignment
        }
    }
    '3' {
        # Generate exemption report
        Write-Host "`n  Exemption Report" -ForegroundColor Cyan
        $report = Get-ExemptionReport -Scope $baseScope
        if ($report.Count -gt 0) {
            $report | Format-Table -AutoSize

            $exportChoice = Read-Host "  Export to CSV? (Y/n)"
            if ($exportChoice -ne 'n' -and $exportChoice -ne 'N') {
                $csvPath = Join-Path $JsonPath "Exemption_Report_$(Get-Date -Format 'yyyyMMdd').csv"
                $report | Export-Csv $csvPath -NoTypeInformation
                Write-Host "  Exported to: $csvPath" -ForegroundColor Green
            }

            # Highlight expiring
            $expiring = @($report | Where-Object { $_.Status -eq "EXPIRING SOON" })
            if ($expiring.Count -gt 0) {
                Write-Host "`n  WARNING: $($expiring.Count) exemption(s) expiring within 30 days:" -ForegroundColor Yellow
                $expiring | Format-Table Name, DisplayName, ExpiresOn -AutoSize
            }
        }
    }
    '4' {
        # Remove expired exemptions
        Write-Host "`n  Remove Expired Exemptions" -ForegroundColor Cyan
        Write-Host "  Preview first (dry run)..." -ForegroundColor Gray
        Remove-ExpiredExemptions -Scope $baseScope -WhatIf

        $confirmRemove = Read-Host "`n  Proceed with removal? (Y/n)"
        if ($confirmRemove -ne 'n' -and $confirmRemove -ne 'N') {
            Remove-ExpiredExemptions -Scope $baseScope
        } else {
            Write-Host "  Removal cancelled." -ForegroundColor Yellow
        }
    }
    '5' {
        # Search policy reference IDs
        Write-Host "`n  Search Policy Reference IDs" -ForegroundColor Cyan
        if ($policyDefs.Count -eq 0) {
            Write-Host "  No policy definitions loaded. Ensure custom_initiative.json exists." -ForegroundColor Yellow
        } else {
            $searchTerm = Read-Host "  Enter search term (e.g. SQL, Kubernetes, network, storage)"
            $found = Find-PolicyReferenceIds -PolicyDefinitions $policyDefs -SearchTerm $searchTerm
            if ($found.Count -eq 0) {
                Write-Host "  No matches for '$searchTerm'." -ForegroundColor Yellow
            } else {
                Write-Host "  Found $($found.Count) matching policies:" -ForegroundColor Green
                $found | Select-Object policyDefinitionReferenceId, policyDefinitionId, definitionVersion |
                    Format-Table -AutoSize
            }
        }
    }
    '6' {
        # List all policy reference IDs
        Write-Host "`n  All Policy Reference IDs ($($policyDefs.Count) total)" -ForegroundColor Cyan
        if ($policyDefs.Count -eq 0) {
            Write-Host "  No policy definitions loaded." -ForegroundColor Yellow
        } else {
            $policyDefs | Select-Object policyDefinitionReferenceId, policyDefinitionId, definitionVersion |
                Format-Table -AutoSize

            $exportChoice = Read-Host "  Export to CSV? (Y/n)"
            if ($exportChoice -ne 'n' -and $exportChoice -ne 'N') {
                $csvPath = Join-Path $JsonPath "policy_reference_ids_$(Get-Date -Format 'yyyyMMdd').csv"
                $policyDefs | Select-Object policyDefinitionReferenceId, policyDefinitionId, definitionVersion |
                    Export-Csv $csvPath -NoTypeInformation
                Write-Host "  Exported to: $csvPath" -ForegroundColor Green
            }
        }
    }
    'Q' {
        Write-Host "  Exiting." -ForegroundColor Gray
    }
    default {
        Write-Host "  Invalid choice." -ForegroundColor Red
    }
}
#endregion

Write-Host "`n============================================================================" -ForegroundColor Cyan
Write-Host " Available Functions (dot-source this script to use directly):" -ForegroundColor Gray
Write-Host "   New-PolicyExemptionForResourceGroup" -ForegroundColor White
Write-Host "   New-PolicyExemptionForSpecificPolicies" -ForegroundColor White
Write-Host "   Get-ExemptionReport -Scope <scope>" -ForegroundColor White
Write-Host "   Remove-ExpiredExemptions -Scope <scope>" -ForegroundColor White
Write-Host "   Get-InitiativePolicyReferences -JsonFilePath <path>" -ForegroundColor White
Write-Host "   Find-PolicyReferenceIds -PolicyDefinitions <array> -SearchTerm <text>" -ForegroundColor White
Write-Host "============================================================================" -ForegroundColor Cyan

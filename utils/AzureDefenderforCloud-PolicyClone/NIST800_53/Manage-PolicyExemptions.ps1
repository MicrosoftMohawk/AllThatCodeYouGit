# ============================================================================
# Policy Exemption Management Script for NIST 800-53 Rev 5 Custom Initiative
# Purpose: Helper functions and examples for creating and managing exemptions
# ============================================================================

#region Configuration
$subscriptionId = "<EnterSubscriptionID>"
$managementGroupId = "<EnterManagementGroupID>"
$assignmentName = "<Enter Custom Assignment Name>"  # Must be 24 characters or less
#endregion

#region Authentication
Connect-AzAccount
Set-AzContext -Subscription $subscriptionId
#endregion

#region Helper Functions

function New-PolicyExemptionForResourceGroup {
    <#
    .SYNOPSIS
        Creates a policy exemption for an entire resource group
    .PARAMETER ResourceGroupName
        Name of the resource group to exempt
    .PARAMETER ExemptionName
        Unique name for the exemption
    .PARAMETER ExemptionCategory
        Waiver or Mitigated
    .PARAMETER ExpirationMonths
        Number of months until exemption expires
    .PARAMETER Reason
        Business justification for the exemption
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory=$true)]
        [string]$ExemptionName,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Waiver", "Mitigated")]
        [string]$ExemptionCategory = "Waiver",
        
        [Parameter(Mandatory=$false)]
        [int]$ExpirationMonths = 6,
        
        [Parameter(Mandatory=$true)]
        [string]$Reason
    )
    
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName"
    $assignment = Get-AzPolicyAssignment -Name $assignmentName
    
    New-AzPolicyExemption `
        -Name $ExemptionName `
        -DisplayName "$ResourceGroupName - $ExemptionCategory" `
        -Description $Reason `
        -Scope $scope `
        -PolicyAssignment $assignment `
        -ExemptionCategory $ExemptionCategory `
        -ExpiresOn (Get-Date).AddMonths($ExpirationMonths) `
        -Metadata (@{
            "CreatedBy" = $env:USERNAME
            "CreatedDate" = (Get-Date).ToString("yyyy-MM-dd")
            "Justification" = $Reason
        } | ConvertTo-Json)
    
    Write-Host "Exemption created for resource group: $ResourceGroupName" -ForegroundColor Green
}

function New-PolicyExemptionForSpecificPolicies {
    <#
    .SYNOPSIS
        Creates an exemption for specific policies within the initiative
    .PARAMETER Scope
        Full scope path (subscription, resource group, or resource)
    .PARAMETER PolicyReferenceIds
        Array of policy reference IDs to exempt
    .PARAMETER ExemptionName
        Unique name for the exemption
    .PARAMETER ExemptionCategory
        Waiver or Mitigated
    .PARAMETER Reason
        Business justification
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Scope,
        
        [Parameter(Mandatory=$true)]
        [string[]]$PolicyReferenceIds,
        
        [Parameter(Mandatory=$true)]
        [string]$ExemptionName,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Waiver", "Mitigated")]
        [string]$ExemptionCategory = "Waiver",
        
        [Parameter(Mandatory=$true)]
        [string]$Reason,
        
        [Parameter(Mandatory=$false)]
        [int]$ExpirationMonths = 6
    )
    
    $assignment = Get-AzPolicyAssignment -Name $assignmentName
    
    New-AzPolicyExemption `
        -Name $ExemptionName `
        -DisplayName "Selective Policy Exemption" `
        -Description $Reason `
        -Scope $Scope `
        -PolicyAssignment $assignment `
        -PolicyDefinitionReferenceId $PolicyReferenceIds `
        -ExemptionCategory $ExemptionCategory `
        -ExpiresOn (Get-Date).AddMonths($ExpirationMonths)
    
    Write-Host "Exemption created for $($PolicyReferenceIds.Count) policies at scope: $Scope" -ForegroundColor Green
}

function Get-ExemptionReport {
    <#
    .SYNOPSIS
        Generates a report of all current exemptions
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$Scope = "/subscriptions/$subscriptionId"
    )
    
    $exemptions = Get-AzPolicyExemption -Scope $Scope
    
    $report = $exemptions | Select-Object `
        Name,
        @{Name="DisplayName";Expression={$_.Properties.DisplayName}},
        @{Name="Category";Expression={$_.Properties.ExemptionCategory}},
        @{Name="ExpiresOn";Expression={$_.Properties.ExpiresOn}},
        @{Name="Scope";Expression={$_.Properties.PolicyAssignmentId}},
        @{Name="Status";Expression={
            if ($_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date)) {
                "EXPIRED"
            } elseif ($_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date).AddDays(30)) {
                "EXPIRING SOON"
            } else {
                "ACTIVE"
            }
        }}
    
    return $report
}

function Remove-ExpiredExemptions {
    <#
    .SYNOPSIS
        Removes all expired exemptions
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$Scope = "/subscriptions/$subscriptionId",
        
        [Parameter(Mandatory=$false)]
        [switch]$WhatIf
    )
    
    $exemptions = Get-AzPolicyExemption -Scope $Scope
    $expired = $exemptions | Where-Object { 
        $_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date)
    }
    
    if ($expired.Count -eq 0) {
        Write-Host "No expired exemptions found." -ForegroundColor Green
        return
    }
    
    Write-Host "Found $($expired.Count) expired exemptions." -ForegroundColor Yellow
    
    foreach ($exemption in $expired) {
        if ($WhatIf) {
            Write-Host "Would remove: $($exemption.Name) (Expired: $($exemption.Properties.ExpiresOn))" -ForegroundColor Gray
        } else {
            Remove-AzPolicyExemption -Id $exemption.ResourceId
            Write-Host "Removed: $($exemption.Name)" -ForegroundColor Green
        }
    }
}

#endregion

#region Example Usage

<#
# Example 1: Exempt an entire development resource group
New-PolicyExemptionForResourceGroup `
    -ResourceGroupName "rg-dev-testing" `
    -ExemptionName "dev-testing-full-exemption" `
    -ExemptionCategory "Waiver" `
    -ExpirationMonths 3 `
    -Reason "Development environment undergoing major refactoring"

# Example 2: Exempt specific SQL-related policies for production VMs
$scope = "/subscriptions/$subscriptionId/resourceGroups/rg-prod"
$policyIds = @(
    "EnableAuditingOnSQLServers",
    "SQLServerAuditingSettings",
    "DeployAuditing"
)

New-PolicyExemptionForSpecificPolicies `
    -Scope $scope `
    -PolicyReferenceIds $policyIds `
    -ExemptionName "prod-sql-audit-exemption" `
    -ExemptionCategory "Mitigated" `
    -Reason "Using third-party SQL auditing solution with compensating controls" `
    -ExpirationMonths 12

# Example 3: Exempt based on resource tags
$devResources = Get-AzResource -TagName "Environment" -TagValue "Development"
foreach ($resource in $devResources) {
    $exemptionName = "dev-auto-$($resource.Name)-$(Get-Date -Format 'MMdd')"
    
    New-PolicyExemptionForResourceGroup `
        -ResourceGroupName $resource.ResourceGroupName `
        -ExemptionName $exemptionName `
        -ExemptionCategory "Waiver" `
        -ExpirationMonths 6 `
        -Reason "Automated exemption for dev resources"
}

# Example 4: Generate exemption report
$report = Get-ExemptionReport
$report | Format-Table -AutoSize
$report | Export-Csv "Exemption_Report_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation

# Example 5: Find and display expiring exemptions
$report = Get-ExemptionReport
$expiring = $report | Where-Object { $_.Status -eq "EXPIRING SOON" }
if ($expiring) {
    Write-Host "`nExemptions expiring within 30 days:" -ForegroundColor Yellow
    $expiring | Format-Table -AutoSize
}

# Example 6: Clean up expired exemptions (test first with -WhatIf)
Remove-ExpiredExemptions -WhatIf
# Remove-ExpiredExemptions  # Uncomment to actually remove

# Example 7: Exempt specific resources by resource ID
$vmResourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-special/providers/Microsoft.Compute/virtualMachines/vm-critical-001"
$assignment = Get-AzPolicyAssignment -Name $assignmentName

New-AzPolicyExemption `
    -Name "vm-critical-001-exemption" `
    -DisplayName "Critical VM Exemption" `
    -Description "Production-critical VM with custom security configuration" `
    -Scope $vmResourceId `
    -PolicyAssignment $assignment `
    -ExemptionCategory "Mitigated" `
    -ExpiresOn (Get-Date).AddYears(1) `
    -Metadata (@{
        "ApprovalTicket" = "JIRA-12345"
        "CompensatingControls" = "Custom IDS/IPS, Manual auditing process"
        "Approver" = "security-team@company.com"
    } | ConvertTo-Json)

#>

#endregion

#region Bulk Operations

<#
# Bulk exemption creation from CSV
# CSV format: ResourceGroupName,ExemptionName,Category,ExpirationMonths,Reason

$csvPath = ".\exemptions_to_create.csv"
if (Test-Path $csvPath) {
    $exemptionsToCreate = Import-Csv $csvPath
    
    foreach ($exemption in $exemptionsToCreate) {
        try {
            New-PolicyExemptionForResourceGroup `
                -ResourceGroupName $exemption.ResourceGroupName `
                -ExemptionName $exemption.ExemptionName `
                -ExemptionCategory $exemption.Category `
                -ExpirationMonths ([int]$exemption.ExpirationMonths) `
                -Reason $exemption.Reason
        } catch {
            Write-Host "Failed to create exemption for $($exemption.ResourceGroupName): $_" -ForegroundColor Red
        }
    }
}

# Bulk exemption removal
$exemptionsToRemove = Import-Csv ".\exemptions_to_remove.csv"  # CSV with "ExemptionName" column
foreach ($exemption in $exemptionsToRemove) {
    try {
        $existing = Get-AzPolicyExemption -Name $exemption.ExemptionName
        Remove-AzPolicyExemption -Id $existing.ResourceId
        Write-Host "Removed exemption: $($exemption.ExemptionName)" -ForegroundColor Green
    } catch {
        Write-Host "Failed to remove exemption $($exemption.ExemptionName): $_" -ForegroundColor Red
    }
}
#>

#endregion

Write-Host "`nPolicy Exemption Management Script Loaded" -ForegroundColor Green
Write-Host "Available Functions:" -ForegroundColor Cyan
Write-Host "  - New-PolicyExemptionForResourceGroup" -ForegroundColor White
Write-Host "  - New-PolicyExemptionForSpecificPolicies" -ForegroundColor White
Write-Host "  - Get-ExemptionReport" -ForegroundColor White
Write-Host "  - Remove-ExpiredExemptions" -ForegroundColor White
Write-Host "`nSee examples in the script for usage." -ForegroundColor Gray

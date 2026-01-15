# ============================================================================
# NIST 800-53 Rev 5 Custom Initiative Deployment Script
# Purpose: Clone built-in NIST R5, create custom initiative, and manage assignments
# ============================================================================

#region Prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

# See current versions
Get-Module Az.Resources -ListAvailable | Select-Object Name, Version

# Import required modules
Import-Module Az.Resources
Import-Module Az.PolicyInsights
#endregion

#region Authentication & Context
# Connect to Azure
Write-Host "`nConnecting to Azure..." -ForegroundColor Cyan
Connect-AzAccount

# Get available subscriptions and prompt user to select one
$subscriptions = Get-AzSubscription
if ($subscriptions.Count -eq 1) {
    $subscriptionId = $subscriptions[0].Id
    Write-Host "Using subscription: $($subscriptions[0].Name) ($subscriptionId)" -ForegroundColor Green
} else {
    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $subscriptions.Count; $i++) {
        Write-Host "  [$i] $($subscriptions[$i].Name) - $($subscriptions[$i].Id)"
    }
    $selection = Read-Host "`nEnter the number of the subscription to use"
    $subscriptionId = $subscriptions[[int]$selection].Id
    Write-Host "Selected: $($subscriptions[[int]$selection].Name)" -ForegroundColor Green
}

Set-AzContext -Subscription $subscriptionId

# Prompt for deployment scope
Write-Host "`nDo you want to deploy to a Management Group or Subscription?" -ForegroundColor Cyan
Write-Host "  [1] Management Group (recommended for enterprise deployments)"
Write-Host "  [2] Subscription (simpler, single subscription scope)"
$scopeChoice = Read-Host "Enter your choice (1 or 2)"

if ($scopeChoice -eq "1") {
    # Get available management groups
    Write-Host "`nRetrieving available management groups..." -ForegroundColor Cyan
    try {
        $managementGroups = Get-AzManagementGroup -ErrorAction Stop
        
        if ($managementGroups.Count -eq 0) {
            Write-Host "ERROR: No management groups found. You may not have access to any management groups." -ForegroundColor Red
            Write-Host "Falling back to subscription scope deployment." -ForegroundColor Yellow
            $managementGroupId = $null
        } elseif ($managementGroups.Count -eq 1) {
            $managementGroupId = $managementGroups[0].Name
            Write-Host "Using management group: $($managementGroups[0].DisplayName) ($managementGroupId)" -ForegroundColor Green
        } else {
            Write-Host "`nAvailable management groups:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $managementGroups.Count; $i++) {
                Write-Host "  [$i] $($managementGroups[$i].DisplayName) - $($managementGroups[$i].Name)"
            }
            $mgSelection = Read-Host "`nEnter the number of the management group to use"
            $managementGroupId = $managementGroups[[int]$mgSelection].Name
            Write-Host "Selected: $($managementGroups[[int]$mgSelection].DisplayName)" -ForegroundColor Green
        }
    } catch {
        Write-Host "ERROR: Failed to retrieve management groups: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Falling back to subscription scope deployment." -ForegroundColor Yellow
        $managementGroupId = $null
    }
    
    # If we successfully selected a management group, verify access
    if ($managementGroupId) {
        try {
            $mg = Get-AzManagementGroup -GroupId $managementGroupId -Expand -ErrorAction Stop
            Write-Host "Verified management group access: $($mg.DisplayName)" -ForegroundColor Green
        } catch {
            Write-Host "ERROR: Cannot access management group '$managementGroupId': $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Please ensure you have appropriate permissions." -ForegroundColor Yellow
            exit 1
        }
    }
} else {
    $managementGroupId = $null
    Write-Host "Deploying to subscription scope: $subscriptionId" -ForegroundColor Green
}
#endregion

#region Step 1: Export Built-in NIST 800-53 R5 Initiative (Optional - if you need to refresh)
Write-Host "`nStep 1: Exporting built-in NIST 800-53 Rev 5 initiative..." -ForegroundColor Cyan

# Get the built-in initiative
$builtInInitiative = Get-AzPolicySetDefinition | Where-Object { 
    $_.Properties.DisplayName -like "*NIST*800-53*Rev*5*" -and $_.Properties.PolicyType -eq "BuiltIn"
}

if ($builtInInitiative) {
    Write-Host "Found built-in initiative: $($builtInInitiative.Properties.DisplayName)" -ForegroundColor Green
    Write-Host "Initiative ID: $($builtInInitiative.ResourceId)" -ForegroundColor Gray
    
    # Export to JSON for reference
    $builtInInitiative | ConvertTo-Json -Depth 100 | Out-File "nist_r5_builtin_export.json"
    Write-Host "Exported to: nist_r5_builtin_export.json" -ForegroundColor Green
} else {
    Write-Host "Built-in NIST initiative not found. Ensure you have the latest Azure Policy definitions." -ForegroundColor Yellow
}
#endregion

#region Step 2: Create Custom Initiative Definition
Write-Host "`nStep 2: Creating custom NIST 800-53 Rev 5 initiative..." -ForegroundColor Cyan

# Load your custom JSON definition
$customJsonPath = ".\nist_r5_custom.json"
if (-not (Test-Path $customJsonPath)) {
    Write-Error "Custom JSON file not found at: $customJsonPath"
    exit
}

# Parse the JSON file
Write-Host "Parsing JSON file..." -ForegroundColor Gray
$jsonContent = Get-Content $customJsonPath -Raw | ConvertFrom-Json

# Extract the properties from the JSON
$properties = $jsonContent.properties
$policyDefinitions = $properties.policyDefinitions

# Validate that we have policy definitions
if (-not $policyDefinitions -or $policyDefinitions.Count -eq 0) {
    Write-Error "No policy definitions found in the JSON file. Check the structure of nist_r5_custom.json"
    exit
}

Write-Host "Found $($policyDefinitions.Count) policy definitions in the initiative" -ForegroundColor Green

# Convert policy definitions back to JSON string for the cmdlet
$policyDefinitionsJson = $policyDefinitions | ConvertTo-Json -Depth 100

# Prompt for custom initiative name
Write-Host "`nCustomize Initiative Name:" -ForegroundColor Cyan
Write-Host "Default name: NIST-800-53-Rev5-Custom_v1.0" -ForegroundColor Gray
Write-Host "Press Enter to use default, or type a custom name" -ForegroundColor Gray
Write-Host "Note: Name must be alphanumeric with hyphens/underscores, max 64 characters" -ForegroundColor Yellow
$customName = Read-Host "Initiative Name"

if ([string]::IsNullOrWhiteSpace($customName)) {
    $initiativeName = "NIST-800-53-Rev5-Custom_v1.0"
    Write-Host "Using default name: $initiativeName" -ForegroundColor Green
} else {
    # Validate the name (alphanumeric, hyphens, underscores only, max 64 chars)
    if ($customName -match '^[a-zA-Z0-9_-]{1,64}$') {
        $initiativeName = $customName
        Write-Host "Using custom name: $initiativeName" -ForegroundColor Green
    } else {
        Write-Host "WARNING: Invalid name format. Using default name instead." -ForegroundColor Yellow
        Write-Host "Name must contain only letters, numbers, hyphens, and underscores (max 64 chars)" -ForegroundColor Yellow
        $initiativeName = "NIST-800-53-Rev5-Custom_v1.0"
        Write-Host "Using default name: $initiativeName" -ForegroundColor Green
    }
}

# Define custom initiative parameters
$displayName = $properties.displayName
$description = $properties.description
$metadata = $properties.metadata | ConvertTo-Json -Depth 10

# Extract parameters if they exist
$parameters = $null
if ($properties.parameters) {
    $parameters = $properties.parameters | ConvertTo-Json -Depth 100
}

# Extract policy definition groups if they exist
$policyDefinitionGroups = $null
if ($properties.policyDefinitionGroups) {
    $policyDefinitionGroups = $properties.policyDefinitionGroups | ConvertTo-Json -Depth 100
}

# Create the custom initiative at Management Group or Subscription scope
try {
    $params = @{
        Name = $initiativeName
        DisplayName = $displayName
        Description = $description
        PolicyDefinition = $policyDefinitionsJson
        Metadata = $metadata
    }
    
    # Add optional parameters
    if ($parameters) {
        $params.Parameter = $parameters
    }
    
    if ($policyDefinitionGroups) {
        $params.GroupDefinition = $policyDefinitionGroups
    }
    
    if ($managementGroupId) {
        # Create at Management Group scope
        $params.ManagementGroupName = $managementGroupId
        $newInitiative = New-AzPolicySetDefinition @params
        
        Write-Host "Custom initiative created at Management Group: $managementGroupId" -ForegroundColor Green
    } else {
        # Create at Subscription scope
        $params.SubscriptionId = $subscriptionId
        $newInitiative = New-AzPolicySetDefinition @params
        
        Write-Host "Custom initiative created at Subscription: $subscriptionId" -ForegroundColor Green
    }
    
    Write-Host "Initiative Resource ID: $($newInitiative.ResourceId)" -ForegroundColor Gray
    Write-Host "Initiative Name: $($newInitiative.Name)" -ForegroundColor Gray
} catch {
    Write-Error "Failed to create custom initiative: $_"
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit
}
#endregion

#region Step 3: Manual Assignment Instructions
Write-Host "`nStep 3: Custom initiative is ready for assignment" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan

Write-Host "`nThe custom NIST 800-53 Rev 5 initiative has been created and is now available." -ForegroundColor Green
Write-Host "To apply it to your resources, assign it manually using one of these methods:" -ForegroundColor White

Write-Host "`n📋 METHOD 1: Azure Portal" -ForegroundColor Yellow
Write-Host "  1. Navigate to: Azure Portal > Policy > Definitions" -ForegroundColor Gray
Write-Host "  2. Set 'Type' filter to 'Custom'" -ForegroundColor Gray
Write-Host "  3. Find '$initiativeName'" -ForegroundColor Gray
Write-Host "  4. Click the initiative, then click 'Assign'" -ForegroundColor Gray
Write-Host "  5. Select scope (Management Group or Subscription)" -ForegroundColor Gray
Write-Host "  6. Configure parameters if needed" -ForegroundColor Gray
Write-Host "  7. Enable 'Create a Managed Identity' for remediation" -ForegroundColor Gray
Write-Host "  8. Review and create the assignment" -ForegroundColor Gray

Write-Host "`n💻 METHOD 2: PowerShell" -ForegroundColor Yellow
Write-Host "  Run the following command:" -ForegroundColor Gray
Write-Host ""
if ($managementGroupId) {
    Write-Host "  `$initiative = Get-AzPolicySetDefinition -Name '$initiativeName' -ManagementGroupName '$managementGroupId'" -ForegroundColor Cyan
    Write-Host "  New-AzPolicyAssignment ```" -ForegroundColor Cyan
    Write-Host "    -Name 'NIST-R5-CustomHHS' ```" -ForegroundColor Cyan
    Write-Host "    -DisplayName '$displayName' ```" -ForegroundColor Cyan
    Write-Host "    -Scope '/providers/Microsoft.Management/managementGroups/$managementGroupId' ```" -ForegroundColor Cyan
    Write-Host "    -PolicySetDefinition `$initiative ```" -ForegroundColor Cyan
} else {
    Write-Host "  `$initiative = Get-AzPolicySetDefinition -Name '$initiativeName' -SubscriptionId '$subscriptionId'" -ForegroundColor Cyan
    Write-Host "  New-AzPolicyAssignment ```" -ForegroundColor Cyan
    Write-Host "    -Name 'NIST-R5-CustomHHS' ```" -ForegroundColor Cyan
    Write-Host "    -DisplayName '$displayName' ```" -ForegroundColor Cyan
    Write-Host "    -Scope '/subscriptions/$subscriptionId' ```" -ForegroundColor Cyan
    Write-Host "    -PolicySetDefinition `$initiative ```" -ForegroundColor Cyan
}
Write-Host "    -Location 'eastus' ```" -ForegroundColor Cyan
Write-Host "    -IdentityType 'SystemAssigned'" -ForegroundColor Cyan

Write-Host "`n⚠️  IMPORTANT NOTES:" -ForegroundColor Yellow
Write-Host "  • Assignment name must be 24 characters or less" -ForegroundColor White
Write-Host "  • Enable 'System Assigned Managed Identity' for auto-remediation" -ForegroundColor White
Write-Host "  • Assign Contributor role to the managed identity after assignment" -ForegroundColor White
Write-Host "  • Compliance evaluation begins 10-30 minutes after assignment" -ForegroundColor White

Write-Host "`n📖 For exemptions and advanced management, see README.md" -ForegroundColor Gray
#endregion

#region Step 4: Next Steps
Write-Host "`nStep 4: Next steps after assignment..." -ForegroundColor Cyan

Write-Host "Once you assign the initiative, you can monitor compliance using:" -ForegroundColor White
Write-Host ""
Write-Host "  # Check compliance summary" -ForegroundColor Gray
if ($managementGroupId) {
    Write-Host "  Get-AzPolicyStateSummary -ManagementGroupName '$managementGroupId'" -ForegroundColor Cyan
} else {
    Write-Host "  Get-AzPolicyStateSummary -SubscriptionId '$subscriptionId'" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  # Get detailed compliance for specific assignment" -ForegroundColor Gray
Write-Host "  `$compliance = Get-AzPolicyState -PolicyAssignmentName 'NIST-R5-CustomHHS'" -ForegroundColor Cyan
Write-Host "  `$compliance | Select-Object ResourceId, ComplianceState | Format-Table" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Trigger on-demand scan" -ForegroundColor Gray
Write-Host "  Start-AzPolicyComplianceScan -AsJob" -ForegroundColor Cyan

Write-Host "`n============================================================================" -ForegroundColor Cyan
Write-Host "INITIATIVE CREATION COMPLETE!" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "`nYour custom NIST 800-53 Rev 5 initiative is ready!\" -ForegroundColor White
Write-Host \"`nNext Steps:\" -ForegroundColor Cyan
if ($managementGroupId) {
    Write-Host \"1. Assign the initiative to your management group '$managementGroupId' (see instructions above)\" -ForegroundColor White
} else {
    Write-Host \"1. Assign the initiative to your subscription (see instructions above)\" -ForegroundColor White
}
Write-Host \"2. Grant RBAC roles to the managed identity created during assignment\" -ForegroundColor White
Write-Host \"3. Wait 10-30 minutes for initial compliance evaluation\" -ForegroundColor White
Write-Host \"4. Monitor compliance in Azure Portal > Policy > Compliance\" -ForegroundColor White
Write-Host \"5. Create policy exemptions as needed using Manage-PolicyExemptions.ps1\" -ForegroundColor White
Write-Host \"6. Run remediation tasks for non-compliant resources\" -ForegroundColor White
Write-Host \"`nFor detailed instructions, see README.md\" -ForegroundColor Gray
#endregion

#region ============================================================================
# UTILITY COMMANDS FOR MANAGING CUSTOM INITIATIVE
# ============================================================================

<#
.SYNOPSIS
    Utility commands for managing your custom NIST 800-53 Rev 5 initiative

.DESCRIPTION
    This section contains useful commands for:
    - Updating the custom initiative
    - Managing assignments
    - Creating and managing exemptions
    - Monitoring compliance
    - Running remediations

.NOTES
    Uncomment and run commands as needed
#>

# ----------------------------------------------------------------------------
# UPDATE CUSTOM INITIATIVE
# ----------------------------------------------------------------------------
<#
# After modifying nist_r5_custom.json, update the initiative:
$jsonContent = Get-Content .\nist_r5_custom.json -Raw | ConvertFrom-Json
$policyDefinitions = $jsonContent.properties.policyDefinitions | ConvertTo-Json -Depth 100

$params = @{
    Name = "<YourInitiativeName>"  # Replace with your actual initiative name
    PolicyDefinition = $policyDefinitions
}

if ($managementGroupId) {
    $params.ManagementGroupName = $managementGroupId
} else {
    $params.SubscriptionId = $subscriptionId
}

# Add other properties if they changed
if ($jsonContent.properties.displayName) {
    $params.DisplayName = $jsonContent.properties.displayName
}
if ($jsonContent.properties.description) {
    $params.Description = $jsonContent.properties.description
}
if ($jsonContent.properties.metadata) {
    $params.Metadata = $jsonContent.properties.metadata | ConvertTo-Json -Depth 10
}
if ($jsonContent.properties.policyDefinitionGroups) {
    $params.GroupDefinition = $jsonContent.properties.policyDefinitionGroups | ConvertTo-Json -Depth 100
}

Set-AzPolicySetDefinition @params
#>

# ----------------------------------------------------------------------------
# MANAGE ASSIGNMENTS
# ----------------------------------------------------------------------------
<#
# List all policy assignments in scope
if ($managementGroupId) {
    $scope = "/providers/Microsoft.Management/managementGroups/$managementGroupId"
} else {
    $scope = "/subscriptions/$subscriptionId"
}
Get-AzPolicyAssignment -Scope $scope

# Get specific assignment
Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS" -Scope $scope

# Remove an assignment
Remove-AzPolicyAssignment -Name "NIST-R5-CustomHHS" -Scope $scope -Confirm:$false
#>

# ----------------------------------------------------------------------------
# CREATE POLICY EXEMPTIONS
# ----------------------------------------------------------------------------
<#
# Example 1: Exempt a specific resource group from all policies in the initiative
$exemption1 = New-AzPolicyExemption `
    -Name "Dev-Environment-Full-Exemption" `
    -DisplayName "Development Environment Full Exemption" `
    -Description "Temporary exemption for dev environment during testing phase" `
    -Scope "/subscriptions/<EnterSubscriptionID>/resourceGroups/rg-dev" `
    -PolicyAssignment (Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS") `
    -ExemptionCategory "Waiver" `
    -ExpiresOn (Get-Date).AddMonths(3)

# Example 2: Exempt specific policies within the initiative for a resource
# First, get the policy reference IDs from your initiative JSON
# Look for "policyDefinitionReferenceId" in nist_r5_custom.json

$exemption2 = New-AzPolicyExemption `
    -Name "SQL-Audit-Exemption-VM001" `
    -DisplayName "SQL Audit Exemption for VM001" `
    -Description "VM001 has compensating controls" `
    -Scope "/subscriptions/<EnterSubscriptionID>/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm001" `
    -PolicyAssignment (Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS") `
    -PolicyDefinitionReferenceId @("EnableAuditingOnSQLServers", "SQLServerAuditingSettings") `
    -ExemptionCategory "Mitigated" `
    -ExpiresOn (Get-Date).AddYears(1) `
    -Metadata (@{
        "CompensatingControl" = "Azure Security Center monitoring enabled"
        "ApprovalTicket" = "SNOW-12345"
    } | ConvertTo-Json)

# Example 3: Exempt based on resource tags
# First, get resources with specific tags
$devResources = Get-AzResource -TagName "Environment" -TagValue "Development"
foreach ($resource in $devResources) {
    New-AzPolicyExemption `
        -Name "dev-exemption-$($resource.Name)" `
        -DisplayName "Development Exemption - $($resource.Name)" `
        -Scope $resource.ResourceId `
        -PolicyAssignment (Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS") `
        -ExemptionCategory "Waiver" `
        -ExpiresOn (Get-Date).AddMonths(6)
}
#>

# ----------------------------------------------------------------------------
# MANAGE EXEMPTIONS
# ----------------------------------------------------------------------------
<#
# List all exemptions in a scope
Get-AzPolicyExemption -Scope "/subscriptions/<EnterSubscriptionID>"

# Get specific exemption
Get-AzPolicyExemption -Name "Dev-Environment-Full-Exemption"

# Update exemption expiration
$exemption = Get-AzPolicyExemption -Name "Dev-Environment-Full-Exemption"
Set-AzPolicyExemption `
    -Id $exemption.ResourceId `
    -ExpiresOn (Get-Date).AddMonths(6)

# Remove an exemption
Remove-AzPolicyExemption -Name "Dev-Environment-Full-Exemption" -Scope "/subscriptions/<EnterSubscriptionID>/resourceGroups/rg-dev"

# Find expiring exemptions (within 30 days)
$allExemptions = Get-AzPolicyExemption -Scope "/subscriptions/<EnterSubscriptionID>"
$expiringExemptions = $allExemptions | Where-Object { 
    $_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date).AddDays(30)
}
$expiringExemptions | Select-Object Name, @{Name="ExpiresOn";Expression={$_.Properties.ExpiresOn}}, @{Name="Scope";Expression={$_.Properties.PolicyAssignmentId}} | Format-Table
#>

# ----------------------------------------------------------------------------
# COMPLIANCE MONITORING
# ----------------------------------------------------------------------------
<#
# Trigger on-demand compliance scan
Start-AzPolicyComplianceScan -AsJob

# Get compliance summary based on deployment scope
if ($managementGroupId) {
    Get-AzPolicyStateSummary -ManagementGroupName "$managementGroupId"
} else {
    Get-AzPolicyStateSummary -SubscriptionId "$subscriptionId"
}

# Get detailed compliance state for specific assignment
$complianceDetails = Get-AzPolicyState -PolicyAssignmentName "NIST-R5-CustomHHS"
$complianceDetails | Select-Object ResourceId, ComplianceState, PolicyDefinitionName, PolicyDefinitionReferenceId | Export-Csv "compliance_report.csv" -NoTypeInformation

# Group by compliance state
$complianceDetails | Group-Object ComplianceState | Select-Object Name, Count | Format-Table

# Show non-compliant resources
$nonCompliant = $complianceDetails | Where-Object { $_.ComplianceState -eq "NonCompliant" }
$nonCompliant | Select-Object ResourceId, PolicyDefinitionName | Format-Table
#>

# ----------------------------------------------------------------------------
# REMEDIATION
# ----------------------------------------------------------------------------
<#
# Create remediation task for all non-compliant resources
$remediationName = "remediate-nist-r5-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$assignment = Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS"

Start-AzPolicyRemediation `
    -Name $remediationName `
    -PolicyAssignmentId $assignment.ResourceId `
    -Scope "/subscriptions/<EnterSubscriptionID>"

# Remediate specific policy within the initiative
Start-AzPolicyRemediation `
    -Name "remediate-sql-audit-$(Get-Date -Format 'yyyyMMdd')" `
    -PolicyAssignmentId $assignment.ResourceId `
    -PolicyDefinitionReferenceId "EnableAuditingOnSQLServers" `
    -Scope "/subscriptions/<EnterSubscriptionID>"

# Monitor remediation progress
Get-AzPolicyRemediation -Name $remediationName -Scope "/subscriptions/<EnterSubscriptionID>"

# List all active remediations
Get-AzPolicyRemediation -Scope "/subscriptions/<EnterSubscriptionID>" | Where-Object { $_.Properties.ProvisioningState -eq "Running" }

# Cancel a remediation
Stop-AzPolicyRemediation -Name $remediationName -Scope "/subscriptions/<EnterSubscriptionID>"
#>

# ----------------------------------------------------------------------------
# EXPORT COMPLIANCE REPORT
# ----------------------------------------------------------------------------
<#
# Generate comprehensive compliance report
$assignment = Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS"
$compliance = Get-AzPolicyState -PolicyAssignmentId $assignment.ResourceId

$report = $compliance | Select-Object `
    @{Name="SubscriptionId";Expression={$_.SubscriptionId}},
    @{Name="ResourceGroup";Expression={$_.ResourceGroup}},
    @{Name="ResourceType";Expression={$_.ResourceType}},
    @{Name="ResourceName";Expression={$_.ResourceId.Split('/')[-1]}},
    @{Name="ComplianceState";Expression={$_.ComplianceState}},
    @{Name="PolicyName";Expression={$_.PolicyDefinitionName}},
    @{Name="PolicyReferenceId";Expression={$_.PolicyDefinitionReferenceId}},
    @{Name="Timestamp";Expression={$_.Timestamp}}

$report | Export-Csv "NIST_R5_Compliance_Report_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation

# Summary by resource group
$rgSummary = $compliance | Group-Object ResourceGroup | Select-Object `
    Name,
    @{Name="TotalResources";Expression={$_.Count}},
    @{Name="Compliant";Expression={($_.Group | Where-Object {$_.ComplianceState -eq "Compliant"}).Count}},
    @{Name="NonCompliant";Expression={($_.Group | Where-Object {$_.ComplianceState -eq "NonCompliant"}).Count}}

$rgSummary | Export-Csv "NIST_R5_Summary_by_RG_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
#>

# ----------------------------------------------------------------------------
# FINDING POLICY DEFINITION REFERENCE IDs
# ----------------------------------------------------------------------------
<#
# To find policy reference IDs for creating targeted exemptions:

# Method 1: Read from the JSON file
$json = Get-Content .\nist_r5_custom.json | ConvertFrom-Json
$policyDefs = $json.properties.policyDefinitions
$policyDefs | Select-Object policyDefinitionReferenceId, @{Name="PolicyId";Expression={$_.policyDefinitionId}} | Format-Table

# Method 2: Export reference IDs to a file
$policyDefs | Select-Object policyDefinitionReferenceId, policyDefinitionId | Export-Csv "policy_reference_ids.csv" -NoTypeInformation

# Method 3: Search for specific policy by name
$policyDefs | Where-Object { $_.policyDefinitionId -like "*SQL*" } | Select-Object policyDefinitionReferenceId, policyDefinitionId
#>

#endregion

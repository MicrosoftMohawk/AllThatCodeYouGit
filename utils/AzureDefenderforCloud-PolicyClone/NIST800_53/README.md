# NIST 800-53 Rev 5 Custom Initiative - Deployment Guide

## Overview
This repository contains scripts and configuration to create a custom clone of Azure's built-in NIST 800-53 Rev 5 policy initiative. The custom version allows you to:
- Modify policy definitions
- Apply to management groups or subscriptions
- Create policy exemptions for specific resources
- Maintain version control over your compliance framework

## Files in This Repository

| File | Purpose |
|------|---------|
| `nist_r5_custom.json` | Custom NIST 800-53 Rev 5 initiative definition (JSON) |
| `Deploy-CustomNIST-Initiative.ps1` | Main deployment script with full workflow |
| `Manage-PolicyExemptions.ps1` | Helper script for creating and managing exemptions |
| `PowerShell_CMDS-HHS.ps1` | Original commands (backup) |

## Prerequisites

### Required Azure Modules
```powershell
# Install or update Azure PowerShell modules
Install-Module Az.Resources -Scope CurrentUser -Force
Install-Module Az.PolicyInsights -Scope CurrentUser -Force

# Import modules
Import-Module Az.Resources
Import-Module Az.PolicyInsights
```

### Required Permissions
- **Management Group Level**: Management Group Contributor or Policy Contributor
- **Subscription Level**: Owner or Policy Contributor
- **For Remediation**: Contributor role (or specific resource permissions)

## Quick Start

### Step 1: Review and Customize the Initiative JSON
The `nist_r5_custom.json` file contains your custom NIST initiative. Key areas to customize:

```json
{
  "properties": {
    "displayName": "NIST-800-53-Rev5-CustomHHS_v1.0",
    "policyType": "Custom",
    "description": "Your custom description here",
    "policyDefinitions": [
      // Array of policy definitions to include
    ]
  }
}
```

**To modify the initiative:**
1. Open `nist_r5_custom.json`
2. Add/remove policies from the `policyDefinitions` array
3. Adjust parameters as needed
4. Save the file

### Step 2: Create the Custom Initiative

Run the main deployment script:

```powershell
.\Deploy-CustomNIST-Initiative.ps1
```

This script will:
1. ✅ Connect to Azure
2. ✅ Export the built-in NIST initiative (for reference)
3. ✅ Create your custom initiative definition
4. ✅ Display instructions for manual assignment

### Step 3: Assign the Initiative

After creating the initiative, assign it manually using the **Azure Portal** or **PowerShell**.

#### Option A: Azure Portal
1. Navigate to **Azure Portal > Policy > Definitions**
2. Set **Type** filter to **Custom**
3. Find **NIST-800-53-Rev5-CustomHHS_v1.0**
4. Click the initiative, then click **Assign**
5. Select your scope (Management Group or Subscription)
6. Configure parameters if needed
7. **Enable "Create a Managed Identity"** for auto-remediation
8. Review and create the assignment

#### Option B: PowerShell
```powershell
$managementGroupId = "YOUR-MG-ID"
$initiative = Get-AzPolicySetDefinition -Name "NIST-800-53-Rev5-CustomHHS_v1.0" -ManagementGroupName $managementGroupId

New-AzPolicyAssignment `
    -Name "NIST-R5-CustomHHS" `
    -DisplayName "NIST 800-53 R5 Custom HHS" `
    -Scope "/providers/Microsoft.Management/managementGroups/$managementGroupId" `
    -PolicySetDefinition $initiative `
    -Location "eastus" `
    -IdentityType "SystemAssigned"

# After assignment, grant RBAC to the managed identity
$assignment = Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS"
New-AzRoleAssignment `
    -ObjectId $assignment.Identity.PrincipalId `
    -RoleDefinitionName "Contributor" `
    -Scope "/providers/Microsoft.Management/managementGroups/$managementGroupId"
```

**Important Notes:**
- Assignment name must be **24 characters or less**
- Enable **System Assigned Managed Identity** for policies that use `deployIfNotExists` or `modify` effects
- Grant the managed identity appropriate RBAC roles (e.g., Contributor) for remediation
- Compliance evaluation begins **10-30 minutes** after assignment

### Step 4: Manage Policy Exemptions

Use the exemption management script:

```powershell
# Load the helper functions
. .\Manage-PolicyExemptions.ps1

# Example: Exempt a development resource group
New-PolicyExemptionForResourceGroup `
    -ResourceGroupName "rg-dev" `
    -ExemptionName "dev-env-exemption" `
    -ExemptionCategory "Waiver" `
    -ExpirationMonths 6 `
    -Reason "Development environment - testing in progress"

# Generate exemption report
$report = Get-ExemptionReport
$report | Format-Table -AutoSize
```

## Common Scenarios

### Scenario 1: Exempt an Entire Resource Group

```powershell
New-PolicyExemptionForResourceGroup `
    -ResourceGroupName "rg-development" `
    -ExemptionName "dev-full-exemption" `
    -ExemptionCategory "Waiver" `
    -ExpirationMonths 3 `
    -Reason "Active development - baseline not yet applied"
```

### Scenario 2: Exempt Specific Policies for a Resource

First, find the policy reference IDs:

```powershell
# View all policy reference IDs in your initiative
$json = Get-Content .\nist_r5_custom.json | ConvertFrom-Json
$json.properties.policyDefinitions | Select-Object policyDefinitionReferenceId | Format-Table
```

Then create the exemption:

```powershell
$scope = "/subscriptions/YOUR-SUB-ID/resourceGroups/rg-prod"
$policyIds = @("EnableAuditingOnSQLServers", "SQLServerAuditingSettings")

New-PolicyExemptionForSpecificPolicies `
    -Scope $scope `
    -PolicyReferenceIds $policyIds `
    -ExemptionName "sql-audit-exemption" `
    -ExemptionCategory "Mitigated" `
    -Reason "Using third-party SQL auditing with compensating controls"
```

### Scenario 3: Exempt Resources by Tag

```powershell
# Get all resources with Environment=Dev tag
$devResources = Get-AzResource -TagName "Environment" -TagValue "Dev"

# Create exemptions for each
foreach ($resource in $devResources) {
    New-PolicyExemptionForResourceGroup `
        -ResourceGroupName $resource.ResourceGroupName `
        -ExemptionName "dev-$($resource.ResourceGroupName)" `
        -ExemptionCategory "Waiver" `
        -ExpirationMonths 6 `
        -Reason "Development resource - automated exemption"
}
```

### Scenario 4: Update the Initiative After Modifications

```powershell
# After editing nist_r5_custom.json, update the deployed initiative
$jsonContent = Get-Content .\nist_r5_custom.json -Raw | ConvertFrom-Json
$policyDefinitions = $jsonContent.properties.policyDefinitions | ConvertTo-Json -Depth 100

$params = @{
    Name = "NIST-800-53-Rev5-CustomHHS_v1.0"
    PolicyDefinition = $policyDefinitions
    ManagementGroupName = "YOUR-MG-ID"
}

# Add other properties if they changed
if ($jsonContent.properties.displayName) {
    $params.DisplayName = $jsonContent.properties.displayName
}

Set-AzPolicySetDefinition @params
```

## Monitoring and Compliance

### View Compliance Status

```powershell
# Get compliance summary
Get-AzPolicyStateSummary -ManagementGroupName "YOUR-MG-ID"

# Get detailed compliance state
$compliance = Get-AzPolicyState -PolicyAssignmentName "NIST-R5-CustomHHS-Assignment"
$compliance | Select-Object ResourceId, ComplianceState, PolicyDefinitionName | Format-Table
```

### Trigger Compliance Scan

```powershell
# Start on-demand compliance evaluation
Start-AzPolicyComplianceScan -AsJob
```

### Export Compliance Report

```powershell
$assignment = Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS-Assignment"
$compliance = Get-AzPolicyState -PolicyAssignmentId $assignment.ResourceId

$compliance | Select-Object `
    ResourceId, 
    ComplianceState, 
    PolicyDefinitionName, 
    @{Name="ResourceGroup";Expression={$_.ResourceGroup}} |
Export-Csv "Compliance_Report_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
```

## Remediation

### Create Remediation Tasks

```powershell
# Remediate all non-compliant resources
$assignment = Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS-Assignment"
$remediationName = "remediate-all-$(Get-Date -Format 'yyyyMMdd')"

Start-AzPolicyRemediation `
    -Name $remediationName `
    -PolicyAssignmentId $assignment.ResourceId `
    -Scope "/subscriptions/YOUR-SUB-ID"

# Monitor remediation progress
Get-AzPolicyRemediation -Name $remediationName
```

### Remediate Specific Policy

```powershell
# Remediate only SQL auditing policies
Start-AzPolicyRemediation `
    -Name "remediate-sql-audit" `
    -PolicyAssignmentId $assignment.ResourceId `
    -PolicyDefinitionReferenceId "EnableAuditingOnSQLServers" `
    -Scope "/subscriptions/YOUR-SUB-ID"
```

## Exemption Management

### View All Exemptions

```powershell
# Generate comprehensive exemption report
$report = Get-ExemptionReport
$report | Format-Table -AutoSize

# Export to CSV
$report | Export-Csv "Exemptions_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
```

### Find Expiring Exemptions

```powershell
$report = Get-ExemptionReport
$expiring = $report | Where-Object { $_.Status -eq "EXPIRING SOON" }
$expiring | Format-Table -AutoSize
```

### Clean Up Expired Exemptions

```powershell
# Test first with -WhatIf
Remove-ExpiredExemptions -WhatIf

# Actually remove
Remove-ExpiredExemptions
```

## Best Practices

### 1. Version Control
- Keep `nist_r5_custom.json` in source control
- Document changes in commit messages
- Use branches for testing changes

### 2. Exemption Management
- Always set expiration dates (use `-ExpiresOn`)
- Document business justification in `-Description`
- Use metadata for approval tickets
- Regular review expiring exemptions

### 3. Testing Changes
- Test initiative changes in a dev/test subscription first
- Use `-WhatIf` parameter when available
- Review compliance impact before production deployment

### 4. RBAC for Managed Identity
After assigning the initiative, grant appropriate roles:

```powershell
$assignment = Get-AzPolicyAssignment -Name "NIST-R5-CustomHHS-Assignment"
$principalId = $assignment.Identity.PrincipalId

# Grant Contributor role at subscription scope
New-AzRoleAssignment `
    -ObjectId $principalId `
    -RoleDefinitionName "Contributor" `
    -Scope "/subscriptions/YOUR-SUB-ID"
```

### 5. Monitoring
- Set up Azure Monitor alerts for compliance changes
- Schedule regular compliance reports
- Review exemptions quarterly

## Troubleshooting

### Issue: Initiative Creation Fails

**Error: "At least one policy definition must be referenced"**

This error occurs when the JSON structure isn't parsed correctly. The script now properly handles this by:
1. Parsing the JSON file
2. Extracting the `policyDefinitions` array from the `properties` section
3. Passing the correct format to `New-AzPolicySetDefinition`

**Other Solutions:**
- Verify JSON is valid: `Get-Content .\nist_r5_custom.json | ConvertFrom-Json`
- Check you have sufficient permissions (Policy Contributor or Owner)
- Ensure initiative name doesn't already exist
- If it exists, delete it first: `Remove-AzPolicySetDefinition -Name "NIST-800-53-Rev5-CustomHHS_v1.0" -ManagementGroupName "YOUR-MG-ID"`

### Issue: Compliance Data Not Showing

**Solution:**
- Wait 10-30 minutes for initial evaluation
- Trigger manual scan: `Start-AzPolicyComplianceScan`
- Check that assignment was successful

### Issue: Remediation Not Working

**Solution:**
- Ensure managed identity has appropriate RBAC roles
- Verify the policy supports remediation (has `deployIfNotExists` or `modify` effect)
- Check remediation task status: `Get-AzPolicyRemediation`

### Issue: Can't Create Exemption

**Solution:**
- Verify you have Policy Contributor or Owner role
- Check that the scope is correctly formatted
- Ensure policy reference IDs are valid (check JSON file)

## Additional Resources

- [Azure Policy Documentation](https://docs.microsoft.com/azure/governance/policy/)
- [NIST 800-53 Rev 5 Overview](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
- [Azure Policy Exemptions](https://docs.microsoft.com/azure/governance/policy/concepts/exemption-structure)
- [Policy Remediation](https://docs.microsoft.com/azure/governance/policy/how-to/remediate-resources)

## Support

For issues or questions:
1. Review the troubleshooting section above
2. Check Azure Activity Log for detailed error messages
3. Verify all prerequisites are met
4. Review script comments for additional guidance

## Change Log

| Date | Version | Changes |
|------|---------|---------|
| 2025-12-18 | 1.0 | Initial custom initiative deployment |

---

**Note:** Always test in a non-production environment before deploying to production.


# See current versions
Get-Module Az.Resources -ListAvailable | Select Name,Version

# Update Az (recommended)
Update-Module Az   # If you don't have admin, use: Install-Module Az -Scope CurrentUser -Force

# Import the resources module for this session
Import-Module Az.Resources



Connect-AzAccount

# Set your subscription context
$subscriptionId = "<YourSubscriptionID>"  # Replace with your subscription ID
Set-AzContext -Subscription $subscriptionId

# Define management group ID
$mg = "<YourManagementGroupID>"    # Replace with your management group ID

# Load the custom JSON definition
$json = Get-Content .\nist_r5_custom.json -Raw

# Create the custom policy set definition
New-AzPolicySetDefinition `
  -Name "NIST-800-53-Rev5-Custom_v1.0" `
  -DisplayName "NIST 800-53 Rev 5 - Custom v1.0" `
  -Description "Customizable clone of NIST SP 800-53 Rev. 5 for organizational baseline." `
  -PolicyDefinition $json `
  -ManagementGroupName $mg


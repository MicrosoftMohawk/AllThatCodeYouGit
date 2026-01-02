
# See current versions
Get-Module Az.Resources -ListAvailable | Select Name,Version

# Update Az (recommended)
Update-Module Az   # If you don't have admin, use: Install-Module Az -Scope CurrentUser -Force

# Import the resources module for this session
Import-Module Az.Resources



Connect-AzAccount
Set-AzContext -Subscription "<EnterSubscriptionID>"  # subscription ID

$mg = "<EnterManagementGroupID>"    # management group ID
$json = Get-Content .\nist_r5_custom.json -Raw
New-AzPolicySetDefinition `
  -Name "NIST-800-53-Rev5-CustomHHS_v1.0" `
  -DisplayName "<Enter Display Name>"  # i.e. "NIST 800-53 Rev 5 - CustomHHS v1.0" `
  -Description "<Enter Description>"   # i.e. "Customizable clone of NIST SP 800-53 Rev. 5 for HHS baseline." `
  -PolicyDefinition $json `
  -ManagementGroupName $mg


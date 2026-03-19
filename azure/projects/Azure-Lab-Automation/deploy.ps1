<#
.SYNOPSIS
    Azure Global Lab — Deployment Wrapper Script
    Validates prerequisites and deploys the Bicep templates to Azure.

.DESCRIPTION
    This script checks for required tools (Azure CLI, Bicep CLI), validates the
    login session, and executes the Bicep deployment at the subscription scope.

    The deployment is tiered:
      Tier 1: Core networking, AD Domain Controllers, Azure Bastion, File Share Witness
      Tier 2: + SQL Server VMs (5 total, including AOAG pair at Site 2 with ILB)
      Tier 3: + Application VMs (CAS + 3 child primaries)

.PARAMETER Location
    Azure region for deployment (e.g., eastus, westus2, centralus).

.PARAMETER BaseName
    Base name prefix for all resources. Max 10 characters.

.PARAMETER DeploymentTier
    Which tier to deploy: 1, 2, or 3 (default: 3 = full lab).

.PARAMETER ColocateSql
    When specified, SQL is installed on the same VM as MCM (CAS/PrimA/PrimB).
    Site 2 AOAG SQL nodes are always deployed as separate VMs.

.PARAMETER SkipDomainJoin
    When specified, SQL and MCM VMs will NOT be domain-joined during deployment.
    By default, all SQL and MCM VMs are automatically joined to the AD domain.

.PARAMETER EnableEntraIntegration
    Enable Entra ID hybrid identity integration. Deploys Entra Connect Sync
    server and a management VM with Entra ID login capability.

.PARAMETER EntraIdDomain
    Entra ID tenant domain (e.g., usaavd.com). Required when -EnableEntraIntegration
    is specified.

.PARAMETER DomainStrategy
    AD domain naming strategy:
      subdomain   = AD domain is ad.{EntraIdDomain} (default, cleanest UPN routing)
      independent = AD domain is separate, EntraIdDomain added as UPN suffix

.PARAMETER EntraConnectPlacement
    Where to install Entra Connect:
      dedicated = New VM (default)
      dc02      = Install on DC02 (saves cost)

.PARAMETER WhatIf
    Preview changes without deploying (Azure What-If).

.PARAMETER Destroy
    Remove all resource groups and resources deployed with the specified -BaseName.

.PARAMETER SubscriptionId
    Target subscription ID. If not set, uses current az CLI default.

.EXAMPLE
    # Deploy full lab (all 3 tiers) to East US
    .\.deploy.ps1 -Location eastus -BaseName azlab -DeploymentTier 3

.EXAMPLE
    # Deploy only core networking and AD (Tier 1)
    .\deploy.ps1 -Location eastus -BaseName azlab -DeploymentTier 1

.EXAMPLE
    # Incrementally add Tier 2 (SQL VMs) onto an existing Tier 1 deployment
    .\deploy.ps1 -Location eastus -BaseName azlab -DeploymentTier 2 -DomainName azlab.local

.EXAMPLE
    # Preview what would be deployed (What-If)
    .\deploy.ps1 -Location eastus -BaseName azlab -WhatIf

.EXAMPLE
    # Deploy to a specific subscription
    .\deploy.ps1 -Location eastus -BaseName azlab -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    # Destroy all resources for a specific lab
    .\deploy.ps1 -BaseName azlab -Location eastus -Destroy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 10)]
    [string]$BaseName,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [ValidateSet(1, 2, 3)]
    [int]$DeploymentTier = 3,

    [string]$SubscriptionId,

    [string]$DomainName,

    [switch]$ColocateSql,

    [switch]$SkipDomainJoin,

    [switch]$EnableEntraIntegration,

    [string]$EntraIdDomain,

    [ValidateSet('subdomain', 'independent')]
    [string]$DomainStrategy = 'subdomain',

    [ValidateSet('dedicated', 'dc02')]
    [string]$EntraConnectPlacement = 'dedicated',

    [string]$TimeZone,

    [ValidateSet('Premium_LRS', 'StandardSSD_LRS', 'Standard_LRS')]
    [string]$OsDiskSku = 'Premium_LRS',

    [switch]$WhatIf,

    [switch]$Destroy
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

# Location is required for deploy/what-if but not for destroy
if (-not $Destroy -and -not $Location) {
    Write-Host "ERROR: -Location is required for deployment. Example: -Location eastus" -ForegroundColor Red
    exit 1
}

# =============================================================================
# Colours & helpers
# =============================================================================
function Write-Header { param([string]$Message) Write-Host "`n============================================================" -ForegroundColor Cyan; Write-Host "  $Message" -ForegroundColor Cyan; Write-Host "============================================================" -ForegroundColor Cyan }
function Write-Step   { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Yellow }
function Write-Ok     { param([string]$Message) Write-Host "   [OK] $Message" -ForegroundColor Green }
function Write-Fail   { param([string]$Message) Write-Host "   [FAIL] $Message" -ForegroundColor Red }

# =============================================================================
# 1. Prerequisite Checks
# =============================================================================
Write-Header "Azure Global Lab — Prerequisite Check"

# --- Azure CLI ----------------------------------------------------------------
Write-Step "Checking Azure CLI..."
try {
    $azVersionOutput = az version 2>&1 | ConvertFrom-Json
    $azCliVersion = $azVersionOutput.'azure-cli'
    if ([version]$azCliVersion -lt [version]'2.20.0') {
        Write-Fail "Azure CLI version $azCliVersion is too old. Minimum required: 2.20.0"
        Write-Host "   Update: https://learn.microsoft.com/cli/azure/install-azure-cli" -ForegroundColor Gray
        exit 1
    }
    Write-Ok "Azure CLI $azCliVersion"
} catch {
    Write-Fail "Azure CLI not found. Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# --- Bicep CLI ----------------------------------------------------------------
Write-Step "Checking Bicep CLI..."
try {
    $bicepVersion = az bicep version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Bicep not installed" }
    Write-Ok $bicepVersion
} catch {
    Write-Host "   Bicep CLI not found. Installing..." -ForegroundColor Yellow
    az bicep install
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to install Bicep CLI. Run manually: az bicep install"
        exit 1
    }
    Write-Ok "Bicep CLI installed"
}

# --- Login session ------------------------------------------------------------
Write-Step "Checking Azure login session..."
try {
    # Use get-access-token instead of account show — it actually validates the
    # token is usable (account show reads cached metadata and succeeds even
    # when the token has been revoked or expired).
    $tokenJson = az account get-access-token 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Token expired or invalid" }
    $account = az account show 2>&1 | ConvertFrom-Json
    if (-not $account) { throw "Not logged in" }
    Write-Ok "Logged in as $($account.user.name) (tenant: $($account.tenantId))"
    Write-Host ""
    Write-Host "   [1] Continue with this account" -ForegroundColor White
    Write-Host "   [2] Log in with a different account" -ForegroundColor White
    $choice = Read-Host "   Select (default: 1)"
    if ($choice -eq '2') {
        Write-Host "   Opening browser login..." -ForegroundColor Yellow
        az login | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Login failed. Run 'az login' manually."
            exit 1
        }
        $account = az account show 2>&1 | ConvertFrom-Json
        Write-Ok "Now logged in as $($account.user.name) (tenant: $($account.tenantId))"
    }
} catch {
    Write-Host "   Not logged in. Opening browser login..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Login failed. Run 'az login' manually."
        exit 1
    }
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Ok "Logged in as $($account.user.name)"
}

# --- Subscription selection ---------------------------------------------------
if ($SubscriptionId) {
    Write-Step "Setting subscription to $SubscriptionId..."
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to set subscription. Verify with: az account list --output table"
        exit 1
    }
    $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
    Write-Ok "$($currentSub.name) ($($currentSub.id))"
} else {
    Write-Step "Detecting current subscription..."
    $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
    Write-Ok "Current subscription: $($currentSub.name) ($($currentSub.id))"
    Write-Host ""
    Write-Host "   [1] Continue with this subscription" -ForegroundColor White
    Write-Host "   [2] Choose a different subscription" -ForegroundColor White
    $subChoice = Read-Host "   Select (default: 1)"
    if ($subChoice -eq '2') {
        # Fetch all enabled subscriptions and display as a numbered list
        $subs = az account list --query "[?state=='Enabled'].{name:name, id:id}" -o json | ConvertFrom-Json
        if (-not $subs -or $subs.Count -eq 0) {
            Write-Fail "No enabled subscriptions found."
            exit 1
        }
        Write-Host ""
        for ($i = 0; $i -lt $subs.Count; $i++) {
            $marker = if ($subs[$i].id -eq $currentSub.id) { ' (current)' } else { '' }
            Write-Host "   [$($i + 1)] $($subs[$i].name) — $($subs[$i].id)$marker" -ForegroundColor White
        }
        Write-Host ""
        $subIndex = Read-Host "   Enter number (1-$($subs.Count))"
        $idx = 0
        if (-not [int]::TryParse($subIndex, [ref]$idx) -or $idx -lt 1 -or $idx -gt $subs.Count) {
            Write-Fail "Invalid selection."
            exit 1
        }
        $selected = $subs[$idx - 1]
        az account set --subscription $selected.id
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to set subscription. Verify with: az account list --output table"
            exit 1
        }
        $currentSub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
        Write-Ok "Subscription set to: $($currentSub.name) ($($currentSub.id))"
    }
}

# =============================================================================
# 1a. Incremental Deployment Detection
# =============================================================================
# When deploying Tier 2+ on top of an existing Tier 1 deployment, re-use the
# existing admin password from Key Vault (so DC extensions are NOT re-triggered
# with a changed protectedSettings).  Also auto-detect domain name.
# =============================================================================
$IsIncremental = $false
$ExistingAdminPassword = ''
$ExistingDomainName = ''

if ($DeploymentTier -ge 2) {
    Write-Step "Checking for existing Tier 1 deployment..."
    $rgIdentity = "$BaseName-rg-identity"
    $rgExists = az group exists --name $rgIdentity 2>&1
    if ($rgExists -eq 'true') {
        Write-Ok "Existing Tier 1 detected — resource group '$rgIdentity' exists."
        $IsIncremental = $true

        # --- Discover Key Vault name ------------------------------------------
        $kvName = az keyvault list --resource-group $rgIdentity --query "[0].name" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($kvName)) {
            $kvName = $kvName.Trim()
            Write-Ok "Key Vault found: $kvName"

            # --- Retrieve existing admin password from Key Vault ---------------
            $kvResult = az keyvault secret show --vault-name $kvName --name vm-admin-password --query value -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($kvResult)) {
                $ExistingAdminPassword = $kvResult.Trim()
                Write-Ok "Existing admin password retrieved from Key Vault (will reuse)."
            } else {
                $kvError = "$kvResult"
                if ($kvError -match 'AADSTS|invalid_grant|InteractionRequired') {
                    Write-Host "   WARNING: Key Vault access failed due to a stale authentication token." -ForegroundColor Yellow
                    Write-Host "   Your Azure CLI session is valid for management operations but the" -ForegroundColor Yellow
                    Write-Host "   Key Vault data-plane token has expired or been invalidated." -ForegroundColor Yellow
                    Write-Host "   Run:  az account clear && az login" -ForegroundColor Cyan
                    Write-Host "   Then re-run this script." -ForegroundColor Yellow
                    exit 1
                } else {
                    Write-Host "   WARNING: Could not retrieve admin password from Key Vault." -ForegroundColor Yellow
                    Write-Host "   Key Vault has no public endpoint. Connect via VPN for incremental deploys." -ForegroundColor Yellow
                    Write-Host "   A new password will be generated. DC extensions may re-run." -ForegroundColor Yellow
                }
                $ExistingAdminPassword = ''
            }
        } else {
            Write-Host "   WARNING: No Key Vault found in $rgIdentity. Treating as fresh deploy." -ForegroundColor Yellow
            $IsIncremental = $false
        }

        # --- Detect domain name from DC01 (if not supplied on CLI) ------------
        if ([string]::IsNullOrWhiteSpace($DomainName)) {
            $dc01Name = "$BaseName-dc01"
            # Avoid parentheses in --scripts — az.cmd shells through cmd.exe
            # which interprets () as grouping operators and breaks the command.
            $domainResult = az vm run-command invoke `
                --resource-group $rgIdentity `
                --name $dc01Name `
                --command-id RunPowerShellScript `
                --scripts "Get-ADDomain | Select-Object -ExpandProperty DnsRoot" `
                --query "value[0].message" -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and $domainResult -match '\.') {
                # The output may contain stdout/stderr markers — grab the FQDN line
                $detected = ($domainResult -split "`n" | Where-Object { $_ -match '\.' -and $_ -notmatch 'Enable' -and $_ -notmatch '\[std' } | Select-Object -Last 1).Trim()
                if (-not [string]::IsNullOrWhiteSpace($detected)) {
                    $ExistingDomainName = $detected
                    Write-Ok "Domain auto-detected from DC01: $ExistingDomainName"
                }
            }
            if ([string]::IsNullOrWhiteSpace($ExistingDomainName)) {
                Write-Host "   Could not auto-detect domain name from DC01." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "   No existing Tier 1 deployment found. Proceeding with full setup." -ForegroundColor Yellow
    }
}

# --- Key Vault Administrator RBAC ---------------------------------------------
$DeployerObjectId = ''
$KvPrincipalType = 'User'

if (-not $IsIncremental) {
    Write-Step "Key Vault Administrator RBAC assignment..."
    Write-Host "   Enter a user (UPN) or Entra ID group name to grant Key Vault Administrator." -ForegroundColor White
    Write-Host "   Examples: john@contoso.com, SG-KeyVaultAdmins" -ForegroundColor Gray
    Write-Host "   Leave blank to skip (you can assign manually later)." -ForegroundColor Gray
    $kvAdminInput = Read-Host "   User UPN or Group name"

    if (-not [string]::IsNullOrWhiteSpace($kvAdminInput)) {
        $kvAdminInput = $kvAdminInput.Trim()

        # Ensure the Graph API token is valid — az ad commands use the Graph
        # resource which has a separate token from ARM.  If the Graph token has
        # expired the ad commands will fail with AADSTS135010.
        az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "   Graph API token expired — re-authenticating for Microsoft Graph..." -ForegroundColor Yellow
            az login --scope https://graph.microsoft.com//.default | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Graph re-authentication failed. Skipping KV RBAC."
                Write-Host "   Run 'az login --scope https://graph.microsoft.com//.default' manually, then retry." -ForegroundColor Gray
            }
        }

        # Try as user first (contains @), then as group
        if ($kvAdminInput -match '@') {
            Write-Host "   Looking up user: $kvAdminInput" -ForegroundColor Gray

            # If the entered UPN matches the currently signed-in user, use
            # az ad signed-in-user (avoids Graph lookup issues with MSA /
            # B2B guest accounts that can't resolve their own UPN).
            if ($account -and $account.user.name -eq $kvAdminInput) {
                $userObjId = az ad signed-in-user show --query id -o tsv 2>&1
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($userObjId)) {
                    $DeployerObjectId = ("$userObjId").Trim()
                    $KvPrincipalType = 'User'
                    Write-Ok "Signed-in user matched — Object ID: $DeployerObjectId"
                } else {
                    Write-Fail "Could not resolve signed-in user object ID. Skipping KV RBAC."
                }
            } else {
                $userObj = az ad user show --id $kvAdminInput --query id -o tsv 2>&1
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($userObj)) {
                    $DeployerObjectId = ("$userObj").Trim()
                    $KvPrincipalType = 'User'
                    Write-Ok "User found — Object ID: $DeployerObjectId"
                } else {
                    Write-Fail "User '$kvAdminInput' not found in Entra ID. Skipping KV RBAC."
                }
            }
        } else {
            Write-Host "   Looking up group: $kvAdminInput" -ForegroundColor Gray
            $groupObj = az ad group show --group $kvAdminInput --query id -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($groupObj)) {
                $DeployerObjectId = $groupObj.Trim()
                $KvPrincipalType = 'Group'
                Write-Ok "Group found — Object ID: $DeployerObjectId"
            } else {
                Write-Fail "Group '$kvAdminInput' not found in Entra ID. Skipping KV RBAC."
            }
        }
    } else {
        Write-Host "   Skipped — no Key Vault Administrator will be assigned." -ForegroundColor Yellow
    }
} else {
    Write-Step "Skipping Key Vault RBAC prompt (incremental deployment)."
    Write-Ok "Key Vault RBAC was configured during Tier 1 deployment."
}

# =============================================================================
# 1b. Destroy Mode — Remove all resources for this BaseName
# =============================================================================
if ($Destroy) {
    Write-Header "DESTROY MODE — Removing all resources for '$BaseName'"

    $rgNames = @(
        "$BaseName-rg-network"
        "$BaseName-rg-identity"
        "$BaseName-rg-main"
        "$BaseName-rg-site1"
        "$BaseName-rg-site2"
    )

    # Check which resource groups actually exist
    $existingRgs = @()
    foreach ($rg in $rgNames) {
        $exists = az group exists --name $rg 2>&1
        if ($exists -eq 'true') {
            $existingRgs += $rg
        }
    }

    if ($existingRgs.Count -eq 0) {
        Write-Host "`n   No resource groups found for base name '$BaseName'. Nothing to delete." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "`n   The following resource groups will be PERMANENTLY DELETED:" -ForegroundColor Red
    foreach ($rg in $existingRgs) {
        Write-Host "     - $rg" -ForegroundColor Red
    }
    Write-Host ""
    $confirm = Read-Host "   Type 'yes' to confirm destruction (this cannot be undone)"
    if ($confirm -ne 'yes') {
        Write-Host "`n   Aborted. No resources were deleted." -ForegroundColor Yellow
        exit 0
    }

    # ── Clean up cross-RG dependencies in snet-pe ────────────────────────────
    # Other deployments (e.g., ArtifactsStorage) may have Private Endpoints
    # and DNS VNet links that reference the lab VNet.  These must be removed
    # before the lab's network RG can be deleted.
    # ─────────────────────────────────────────────────────────────────────────
    $networkRg = "$BaseName-rg-network"
    $labVnetName = "$BaseName-vnet"
    if ($existingRgs -contains $networkRg) {
        Write-Step "Checking for cross-resource-group dependencies in the lab VNet..."

        # Find Private Endpoints whose NIC lives in a different RG (e.g., artifacts-rg-artifacts)
        $peSubnetId = az network vnet subnet show `
            -g $networkRg --vnet-name $labVnetName -n snet-pe `
            --query id -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($peSubnetId)) {
            $peJsonRaw = az network private-endpoint list `
                --query "[?subnet.id=='$($peSubnetId.Trim())' && !starts_with(resourceGroup, '$BaseName')].{name:name, rg:resourceGroup, id:id}" `
                -o json 2>&1
            $externalPEs = $null
            if ($LASTEXITCODE -eq 0) {
                try { $externalPEs = $peJsonRaw | ConvertFrom-Json } catch { $externalPEs = $null }
            }

            if ($externalPEs -and $externalPEs.Count -gt 0) {
                Write-Host "   Found $($externalPEs.Count) Private Endpoint(s) from other deployments in snet-pe:" -ForegroundColor Yellow
                foreach ($extPe in $externalPEs) {
                    Write-Host "     - $($extPe.name) (RG: $($extPe.rg))" -ForegroundColor Yellow
                }
                Write-Host ""
                Write-Host "   These must be deleted first, or lab VNet deletion will fail." -ForegroundColor Yellow
                Write-Host "   [1] Delete them now and continue (recommended)" -ForegroundColor White
                Write-Host "   [2] Skip — I'll clean them up manually" -ForegroundColor White
                $peChoice = Read-Host "   Select (default: 1)"
                if ($peChoice -ne '2') {
                    foreach ($extPe in $externalPEs) {
                        Write-Host "   Deleting PE: $($extPe.name) in $($extPe.rg)..." -ForegroundColor Gray
                        az network private-endpoint delete --ids $extPe.id -o none 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            Write-Fail "Failed to delete $($extPe.name). You may need to delete its resource group first."
                        } else {
                            Write-Ok "Deleted $($extPe.name)"
                        }
                    }
                }
            }
        }

        # Find Private DNS Zone VNet links that reference the lab VNet from other RGs
        $labVnetId = az network vnet show -g $networkRg -n $labVnetName --query id -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($labVnetId)) {
            $labVnetId = $labVnetId.Trim()

            # Check known privatelink DNS zones that may have been created by add-on projects
            $dnsZoneNames = @(
                'privatelink.file.core.windows.net'
                'privatelink.blob.core.windows.net'
                'privatelink.table.core.windows.net'
                'privatelink.queue.core.windows.net'
            )
            foreach ($zoneName in $dnsZoneNames) {
                # Search for DNS zones with VNet links to our VNet in the lab's network RG
                $zoneJsonRaw = az network private-dns link vnet list `
                    --zone-name $zoneName `
                    --resource-group "$BaseName-rg-network" `
                    --query "[?virtualNetwork.id=='$labVnetId']" `
                    -o json 2>&1
                $zoneLinks = $null
                if ($LASTEXITCODE -eq 0) {
                    try { $zoneLinks = $zoneJsonRaw | ConvertFrom-Json } catch { $zoneLinks = $null }
                }

                if (-not $zoneLinks -or $zoneLinks.Count -eq 0) {
                    # Also check common add-on RG naming patterns
                    $addOnRgs = az group list --query "[?!starts_with(name, '$BaseName') && contains(name, 'artifacts')].name" -o tsv 2>&1
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($addOnRgs)) {
                        foreach ($addOnRg in ($addOnRgs -split "`n" | Where-Object { $_ })) {
                            $addOnRg = $addOnRg.Trim()
                            $linksJsonRaw = az network private-dns link vnet list `
                                --zone-name $zoneName `
                                --resource-group $addOnRg `
                                --query "[?virtualNetwork.id=='$labVnetId'].{name:name, zone:split(id,'/')[8]}" `
                                -o json 2>&1
                            $links = $null
                            if ($LASTEXITCODE -eq 0) {
                                try { $links = $linksJsonRaw | ConvertFrom-Json } catch { $links = $null }
                            }
                            if ($links -and $links.Count -gt 0) {
                                foreach ($link in $links) {
                                    Write-Host "   Removing DNS VNet link '$($link.name)' from zone '$zoneName' in RG '$addOnRg'..." -ForegroundColor Gray
                                    az network private-dns link vnet delete `
                                        --name $link.name `
                                        --zone-name $zoneName `
                                        --resource-group $addOnRg `
                                        --yes -o none 2>&1
                                    if ($LASTEXITCODE -eq 0) {
                                        Write-Ok "Removed DNS link: $($link.name)"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    # Delete non-network RGs first (async), then network RG last (synchronous)
    # so VNet/subnet deletion waits for dependent NIC cleanups to complete.
    $nonNetworkRgs = @($existingRgs | Where-Object { $_ -ne $networkRg })
    $hasNetworkRg = $existingRgs -contains $networkRg

    foreach ($rg in $nonNetworkRgs) {
        Write-Step "Deleting resource group: $rg"
        az group delete --name $rg --yes --no-wait
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to initiate deletion for $rg"
        } else {
            Write-Ok "Deletion initiated for $rg (running in background)"
        }
    }

    if ($hasNetworkRg) {
        if ($nonNetworkRgs.Count -gt 0) {
            Write-Step "Waiting for non-network resource groups to finish deleting..."
            $waitFailed = $false
            foreach ($rg in $nonNetworkRgs) {
                Write-Host "   Waiting on $rg..." -ForegroundColor Gray
                az group wait --name $rg --deleted --timeout 600 2>&1
                if ($LASTEXITCODE -ne 0) {
                    # az group wait exits non-zero if the RG still exists (timeout) OR
                    # exits 0 / 3 (not found) if it was already deleted.  Verify explicitly.
                    $stillExists = az group exists --name $rg 2>&1
                    if ($stillExists -eq 'true') {
                        Write-Fail "Timed out waiting for $rg to delete — it still exists"
                        $waitFailed = $true
                    } else {
                        Write-Ok "$rg confirmed deleted"
                    }
                } else {
                    Write-Ok "$rg deleted"
                }
            }

            if ($waitFailed) {
                Write-Fail "One or more non-network RGs are still being deleted."
                Write-Host "   Cannot safely delete $networkRg while dependents remain." -ForegroundColor Yellow
                Write-Host "   Re-run this script with -Destroy once the pending deletions complete." -ForegroundColor Yellow
                Write-Host "   Monitor: az group list --query `"[?starts_with(name,'$BaseName')]`" -o table" -ForegroundColor Gray
                exit 1
            }

            # Brief buffer for ARM to fully deregister NICs from subnets (eventual consistency)
            Write-Host "   Allowing time for ARM to deregister subnet references..." -ForegroundColor Gray
            Start-Sleep -Seconds 30
        }

        Write-Step "Deleting network resource group: $networkRg (synchronous — this may take a few minutes)"
        az group delete --name $networkRg --yes
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to delete $networkRg"
            Write-Host "   This usually means a dependent resource still references the VNet." -ForegroundColor Yellow
            Write-Host "   Check for leftover Private Endpoints or DNS links, then retry." -ForegroundColor Yellow
            exit 1
        }
        Write-Ok "$networkRg deleted"
    }

    # ── Post-destroy verification ────────────────────────────────────────────
    Write-Step "Verifying all resource groups are removed..."
    $remaining = @()
    foreach ($rg in $existingRgs) {
        $stillExists = az group exists --name $rg 2>&1
        if ($stillExists -eq 'true') {
            $remaining += $rg
        }
    }

    if ($remaining.Count -gt 0) {
        Write-Header "Destroy Incomplete"
        Write-Host "   The following resource groups still exist:" -ForegroundColor Yellow
        foreach ($rg in $remaining) {
            Write-Host "     - $rg" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "   Re-run with -Destroy once these finish deleting, or remove manually:" -ForegroundColor Gray
        Write-Host "   az group delete --name <rg-name> --yes" -ForegroundColor Gray
        exit 1
    }

    Write-Header "Destroy Complete"
    Write-Host "   All resource groups for '$BaseName' have been deleted." -ForegroundColor Green
    Write-Host ""
    exit 0
}

# --- Validate template --------------------------------------------------------
Write-Step "Validating Bicep template..."
$templateFile = Join-Path $ScriptRoot 'main.bicep'

if (-not (Test-Path $templateFile)) {
    Write-Fail "main.bicep not found at: $templateFile"
    exit 1
}

az bicep build --file $templateFile 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Bicep template has compilation errors. Run: az bicep build --file main.bicep"
    exit 1
}
Write-Ok "Template compiled successfully"

# =============================================================================
# 2. Admin Password — reuse from Key Vault on incremental deploys
# =============================================================================
if ($IsIncremental -and -not [string]::IsNullOrWhiteSpace($ExistingAdminPassword)) {
    Write-Step "Reusing existing admin password from Key Vault..."
    $AdminPassword = $ExistingAdminPassword
    Write-Ok "Admin password retrieved — DC extensions will NOT be re-triggered."
} else {
    Write-Step "Generating secure admin password..."
    # Cryptographically random 24-char password (uppercase, lowercase, digits, symbols)
    # NOTE: Avoid & % ^ | < > ! * characters — they break cmd.exe argument
    # parsing when the password is passed inline to az.cmd on Windows.
    $pwChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#_-+'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(24)
    $rng.GetBytes($bytes)
    $AdminPassword = -join ($bytes | ForEach-Object { $pwChars[$_ % $pwChars.Length] })
    # Ensure complexity: inject one of each class at random positions
    $AdminPassword = $AdminPassword.Substring(0, 20) + 'Aa1@'
    Write-Ok "Password generated (will be stored securely in Key Vault)"
    Write-Host "   The password will NOT be displayed. Retrieve it after deployment with:" -ForegroundColor Gray
    Write-Host "   az keyvault secret show --vault-name <keyvault-name> --name vm-admin-password --query value -o tsv" -ForegroundColor Gray
}

# =============================================================================
# 3. Domain Name — use CLI param, auto-detect, or prompt
# =============================================================================
Write-Step "Active Directory domain configuration..."
# Priority: 1) -DomainName param, 2) auto-detected from DC01, 3) interactive prompt
if (-not [string]::IsNullOrWhiteSpace($DomainName)) {
    Write-Ok "Domain (from parameter): $DomainName"
} elseif (-not [string]::IsNullOrWhiteSpace($ExistingDomainName)) {
    $DomainName = $ExistingDomainName
    Write-Ok "Domain (auto-detected from DC01): $DomainName"
} else {
    $DomainName = Read-Host "   Enter the AD domain name (e.g., azlab.local)"
}
if ([string]::IsNullOrWhiteSpace($DomainName) -or $DomainName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
    Write-Fail "Invalid domain name. Must be a valid FQDN (e.g., azlab.local)"
    exit 1
}
Write-Ok "Domain: $DomainName (NetBIOS: $($DomainName.Split('.')[0].ToUpper()))"

# =============================================================================
# 3aa0. Entra ID Integration Configuration
# =============================================================================
$EnableEntraBool = [bool]$EnableEntraIntegration

if (-not $EnableEntraBool) {
    Write-Step "Entra ID hybrid identity integration..."
    Write-Host ""
    Write-Host "   Enable Entra ID integration to deploy:" -ForegroundColor White
    Write-Host "     - Entra Connect Sync (syncs on-prem AD identities to Entra ID)" -ForegroundColor Gray
    Write-Host "     - UPN suffix configuration in AD for Entra ID domain" -ForegroundColor Gray
    Write-Host "     - Enables Entra ID Kerberos for Azure Files" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   NOTE: The management VM (Entra ID joined) is deployed separately" -ForegroundColor Yellow
    Write-Host "   after the lab is running via: .\deploy-mgmt.ps1" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Prerequisites: Entra ID tenant, Azure AD P2 license" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   [1] Skip (AD-only deployment)" -ForegroundColor White
    Write-Host "   [2] Enable Entra ID integration" -ForegroundColor White
    $entraChoice = Read-Host "   Select (default: 1)"
    if ($entraChoice -eq '2') {
        $EnableEntraBool = $true
    }
}

if ($EnableEntraBool) {
    # --- Entra ID Domain ---
    if ([string]::IsNullOrWhiteSpace($EntraIdDomain)) {
        $EntraIdDomain = Read-Host "   Enter your Entra ID tenant domain (e.g., usaavd.com)"
    }
    if ([string]::IsNullOrWhiteSpace($EntraIdDomain) -or $EntraIdDomain -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
        Write-Fail "Invalid Entra ID domain. Must be a valid FQDN (e.g., usaavd.com)"
        exit 1
    }
    $EntraIdDomain = $EntraIdDomain.Trim()
    Write-Ok "Entra ID domain: $EntraIdDomain"

    # --- Domain Strategy ---
    if (-not $PSBoundParameters.ContainsKey('DomainStrategy')) {
        Write-Host ""
        Write-Host "   AD domain naming strategy:" -ForegroundColor White
        Write-Host "   [1] Subdomain: AD domain = ad.$EntraIdDomain (recommended, UPNs match)" -ForegroundColor White
        Write-Host "   [2] Independent: AD domain = $DomainName (UPN suffix $EntraIdDomain added to AD)" -ForegroundColor White
        $dsChoice = Read-Host "   Select (default: 1)"
        if ($dsChoice -eq '2') {
            $DomainStrategy = 'independent'
        } else {
            $DomainStrategy = 'subdomain'
        }
    }
    Write-Ok "Domain strategy: $DomainStrategy"

    # Auto-derive domain name in subdomain mode
    if ($DomainStrategy -eq 'subdomain') {
        $DomainName = "ad.$EntraIdDomain"
        Write-Ok "AD domain auto-set to: $DomainName (subdomain of $EntraIdDomain)"
    }

    # --- Entra Connect Placement ---
    if (-not $PSBoundParameters.ContainsKey('EntraConnectPlacement')) {
        Write-Host ""
        Write-Host "   Entra Connect Sync placement:" -ForegroundColor White
        Write-Host "   [1] Dedicated VM (recommended for production parity)" -ForegroundColor White
        Write-Host "   [2] Install on DC02 (saves cost)" -ForegroundColor White
        $ecpChoice = Read-Host "   Select (default: 1)"
        if ($ecpChoice -eq '2') {
            $EntraConnectPlacement = 'dc02'
        } else {
            $EntraConnectPlacement = 'dedicated'
        }
    }
    Write-Ok "Entra Connect placement: $EntraConnectPlacement"
} else {
    $EntraIdDomain = ''
    Write-Step "Entra ID integration: DISABLED (AD-only deployment)"
}

# =============================================================================
# 3aa. VM Timezone Selection
# =============================================================================
$timezoneOptions = [ordered]@{
    '1' = @{ Name = 'Eastern Standard Time';  Display = 'Eastern  (UTC-5)' }
    '2' = @{ Name = 'Central Standard Time';  Display = 'Central  (UTC-6)' }
    '3' = @{ Name = 'Mountain Standard Time'; Display = 'Mountain (UTC-7)' }
    '4' = @{ Name = 'Pacific Standard Time';  Display = 'Pacific  (UTC-8)' }
    '5' = @{ Name = 'UTC';                    Display = 'UTC' }
}

if (-not [string]::IsNullOrWhiteSpace($TimeZone)) {
    $VmTimeZone = $TimeZone
    Write-Ok "VM Timezone (from parameter): $VmTimeZone"
} else {
    Write-Step "Select VM timezone..."
    foreach ($key in $timezoneOptions.Keys) {
        $opt = $timezoneOptions[$key]
        Write-Host "   [$key] $($opt.Display)" -ForegroundColor White
    }
    Write-Host "   [6] Custom (enter Windows timezone name)" -ForegroundColor White
    $tzChoice = Read-Host "`n   Enter choice (1-6, default: 1 — Eastern)"
    if ([string]::IsNullOrWhiteSpace($tzChoice)) { $tzChoice = '1' }

    if ($tzChoice -match '^[1-5]$') {
        $VmTimeZone = $timezoneOptions[$tzChoice].Name
    } elseif ($tzChoice -eq '6') {
        $VmTimeZone = Read-Host "   Enter Windows timezone name (e.g., 'Hawaiian Standard Time')"
    } else {
        Write-Fail "Invalid choice. Defaulting to Eastern Standard Time."
        $VmTimeZone = 'Eastern Standard Time'
    }
}
Write-Ok "VM Timezone: $VmTimeZone"

# =============================================================================
# 3a. Server Naming Convention + Colocated SQL Option
# =============================================================================
# Default VM names (max 15 chars for Windows computer name)
$VmNames = [ordered]@{
    SqlCas   = "$BaseName-sqcs"
    SqlPrimA = "$BaseName-sqpa"
    SqlPrimB = "$BaseName-sqpb"
    SqlAoag1 = "$BaseName-sqc1"
    SqlAoag2 = "$BaseName-sqc2"
    Cas      = "$BaseName-cas"
    PrimA    = "$BaseName-prma"
    PrimB    = "$BaseName-prmb"
    PrimC    = "$BaseName-prmc"
}
$ColocateSqlBool = [bool]$ColocateSql

Write-Step "Server naming and SQL placement..."
Write-Host ""
Write-Host "   Current VM naming plan (max 15 chars each):" -ForegroundColor White
Write-Host "   ──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "   Role                 Site       Default Name" -ForegroundColor Cyan
Write-Host "   ──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
if (-not $ColocateSqlBool) {
    Write-Host "   SQL (CAS)            Main       $($VmNames.SqlCas)" -ForegroundColor Gray
    Write-Host "   SQL (Primary A)      Main       $($VmNames.SqlPrimA)" -ForegroundColor Gray
    Write-Host "   SQL (Primary B)      Site 1     $($VmNames.SqlPrimB)" -ForegroundColor Gray
}
Write-Host "   SQL AOAG Node 1      Site 2     $($VmNames.SqlAoag1)" -ForegroundColor Gray
Write-Host "   SQL AOAG Node 2      Site 2     $($VmNames.SqlAoag2)" -ForegroundColor Gray
Write-Host "   MCM CAS              Main       $($VmNames.Cas)" -ForegroundColor Gray
Write-Host "   MCM Primary A        Main       $($VmNames.PrimA)" -ForegroundColor Gray
Write-Host "   MCM Primary B        Site 1     $($VmNames.PrimB)" -ForegroundColor Gray
Write-Host "   MCM Primary C        Site 2     $($VmNames.PrimC)" -ForegroundColor Gray
Write-Host "   ──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
if ($ColocateSqlBool) {
    Write-Host "   ** SQL colocated on MCM servers (CAS/PrimA/PrimB). No separate SQL VMs." -ForegroundColor Yellow
    Write-Host "      Site 2 AOAG SQL nodes are always deployed separately." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "   [1] Accept defaults" -ForegroundColor White
Write-Host "   [2] Customize names" -ForegroundColor White
if (-not $ColocateSql) {
    Write-Host "   [3] Toggle SQL colocated on MCM servers (currently: SEPARATE)" -ForegroundColor White
} else {
    Write-Host "   [3] Toggle SQL colocated on MCM servers (currently: COLOCATED)" -ForegroundColor White
}
$namingChoice = Read-Host "   Select (default: 1)"

if ($namingChoice -eq '3') {
    $ColocateSqlBool = -not $ColocateSqlBool
    if ($ColocateSqlBool) {
        Write-Ok "SQL will be colocated on MCM servers (no separate SQL VMs for CAS/PrimA/PrimB)."
    } else {
        Write-Ok "SQL will be on separate VMs."
    }
    # After toggling, show a simplified prompt for name customization
    Write-Host ""
    Write-Host "   [1] Accept default names" -ForegroundColor White
    Write-Host "   [2] Customize names" -ForegroundColor White
    $namingChoice = Read-Host "   Select (default: 1)"
}

if ($namingChoice -eq '2') {
    Write-Host ""
    Write-Host "   Enter new names below. Press Enter to keep the default shown in [brackets]." -ForegroundColor White
    Write-Host "   Names must be 1-15 characters (Windows computer name limit)." -ForegroundColor Gray
    Write-Host ""

    $namePrompts = [ordered]@{}
    if (-not $ColocateSqlBool) {
        $namePrompts['SqlCas']   = "SQL (CAS)        "
        $namePrompts['SqlPrimA'] = "SQL (Primary A)  "
        $namePrompts['SqlPrimB'] = "SQL (Primary B)  "
    }
    $namePrompts['SqlAoag1'] = "SQL AOAG Node 1  "
    $namePrompts['SqlAoag2'] = "SQL AOAG Node 2  "
    $namePrompts['Cas']      = "MCM CAS          "
    $namePrompts['PrimA']    = "MCM Primary A    "
    $namePrompts['PrimB']    = "MCM Primary B    "
    $namePrompts['PrimC']    = "MCM Primary C    "

    foreach ($key in $namePrompts.Keys) {
        $default = $VmNames[$key]
        $input = Read-Host "   $($namePrompts[$key]) [$default]"
        if (-not [string]::IsNullOrWhiteSpace($input)) {
            $input = $input.Trim()
            if ($input.Length -gt 15) {
                Write-Fail "'$input' exceeds 15 characters. Using default '$default'."
            } else {
                $VmNames[$key] = $input
            }
        }
    }
}

# Display final naming
Write-Host ""
Write-Host "   Final VM names:" -ForegroundColor Cyan
if (-not $ColocateSqlBool) {
    Write-Host "   SQL:  $($VmNames.SqlCas), $($VmNames.SqlPrimA), $($VmNames.SqlPrimB), $($VmNames.SqlAoag1), $($VmNames.SqlAoag2)" -ForegroundColor Green
} else {
    Write-Host "   SQL (AOAG only): $($VmNames.SqlAoag1), $($VmNames.SqlAoag2)" -ForegroundColor Green
    Write-Host "   SQL colocated on: $($VmNames.Cas), $($VmNames.PrimA), $($VmNames.PrimB)" -ForegroundColor Green
}
Write-Host "   MCM: $($VmNames.Cas), $($VmNames.PrimA), $($VmNames.PrimB), $($VmNames.PrimC)" -ForegroundColor Green

# =============================================================================
# 3b. Domain Join Option
# =============================================================================
$JoinDomainBool = -not [bool]$SkipDomainJoin   # default = join domain

if (-not $SkipDomainJoin) {
    Write-Step "Domain join configuration..."
    Write-Host ""
    Write-Host "   SQL, MCM, and Entra Connect VMs can be automatically domain-joined" -ForegroundColor White
    Write-Host "   during deployment using the svc-domjoin service account." -ForegroundColor Gray
    Write-Host "   (The management VM is always Entra ID joined, not AD domain-joined.)" -ForegroundColor Gray
    Write-Host "   SQL VMs -> OU=SQL Servers,OU=Lab Servers" -ForegroundColor Gray
    Write-Host "   MCM/Entra Connect VMs -> OU=App Servers,OU=Lab Servers" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   [1] Domain-join all SQL and MCM VMs (recommended)" -ForegroundColor White
    Write-Host "   [2] Skip domain join — deploy as workgroup servers" -ForegroundColor White
    $djChoice = Read-Host "   Select (default: 1)"
    if ($djChoice -eq '2') {
        $JoinDomainBool = $false
        Write-Ok "VMs will be deployed as workgroup servers (no domain join)."
    } else {
        Write-Ok "VMs will be automatically domain-joined to $DomainName."
    }
} else {
    Write-Step "Domain join: SKIPPED (via -SkipDomainJoin flag)"
    Write-Ok "VMs will be deployed as workgroup servers."
}

# =============================================================================
# 3b. VPN Gateway — Self-Signed Certificate for P2S
# =============================================================================
# Cert lookup is store-based: we search CurrentUser\My for certs whose Subject
# CN matches the deployment BaseName.  This means incremental deploys (even from
# the same machine with a regenerated admin password) always re-export the PFX
# with the *current* password, eliminating the password-desync problem that
# occurs when Key Vault is unreachable behind its private endpoint.
# =============================================================================
Write-Step "VPN Gateway P2S certificate setup..."
$CertDir = Join-Path $ScriptRoot 'certs'
$RootCertPath = Join-Path $CertDir 'P2SRootCert.cer'
$ClientPfxPath = Join-Path $CertDir 'P2SClientCert.pfx'

# --- Step 1: Search the personal certificate store for existing certs --------
$rootCertSubject  = "CN=P2SRootCert-$BaseName"
$clientCertSubject = "CN=P2SClientCert-$BaseName"

$rootCert = Get-ChildItem -Path 'Cert:\CurrentUser\My' |
    Where-Object { $_.Subject -eq $rootCertSubject } |
    Sort-Object NotAfter -Descending | Select-Object -First 1

$clientCert = Get-ChildItem -Path 'Cert:\CurrentUser\My' |
    Where-Object { $_.Subject -eq $clientCertSubject } |
    Sort-Object NotAfter -Descending | Select-Object -First 1

if ($rootCert -and $clientCert) {
    # --- Reuse existing certs from the personal store -------------------------
    Write-Ok "Root cert found in store: $($rootCert.Subject) (Thumbprint: $($rootCert.Thumbprint), Expires: $($rootCert.NotAfter.ToString('yyyy-MM-dd')))"
    Write-Ok "Client cert found in store: $($clientCert.Subject) (Thumbprint: $($clientCert.Thumbprint), Expires: $($clientCert.NotAfter.ToString('yyyy-MM-dd')))"
} else {
    # --- Create new certs (fresh deploy or different workstation) --------------
    Write-Host "   Generating self-signed root CA and client certificate..." -ForegroundColor Yellow

    $rootCert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $rootCertSubject `
        -KeySpec Signature `
        -KeyExportPolicy Exportable `
        -KeyLength 2048 `
        -HashAlgorithm sha256 `
        -KeyUsageProperty Sign `
        -KeyUsage CertSign `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(3)

    Write-Ok "Root CA created: $($rootCert.Subject) (Thumbprint: $($rootCert.Thumbprint))"

    $clientCert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $clientCertSubject `
        -KeySpec Signature `
        -KeyExportPolicy Exportable `
        -KeyLength 2048 `
        -HashAlgorithm sha256 `
        -Signer $rootCert `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(3)

    Write-Ok "Client cert created: $($clientCert.Subject) (Thumbprint: $($clientCert.Thumbprint))"
}

# --- Step 2: Always (re-)export cert files with the current admin password ---
# This ensures the PFX password always matches the admin password that will be
# stored in Key Vault, regardless of whether it was reused or regenerated.
if (-not (Test-Path $CertDir)) { New-Item -Path $CertDir -ItemType Directory -Force | Out-Null }

# Export root cert public key as Base64 .cer
$rootDer = $rootCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$rootCertBase64 = [Convert]::ToBase64String($rootDer)
$rootPem = "-----BEGIN CERTIFICATE-----`r`n$rootCertBase64`r`n-----END CERTIFICATE-----"
Set-Content -Path $RootCertPath -Value $rootPem -Encoding Ascii
Write-Ok "Root cert exported: $RootCertPath"

# Export client cert as PFX (TripleDES_SHA1 for cross-OS compatibility).
# If the existing cert's private key is non-exportable (created by an older
# version of the script or imported without the exportable flag), delete it
# and recreate with -KeyExportPolicy Exportable so re-export always works.
# If the root cert also lacks a usable private key (imported from .cer or
# corrupted), both certs are recreated from scratch.
$pfxPwd = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
try {
    Export-PfxCertificate -Cert $clientCert -FilePath $ClientPfxPath `
        -Password $pfxPwd -CryptoAlgorithmOption TripleDES_SHA1 | Out-Null
} catch {
    if ($_.Exception.Message -match 'non-exportable|private key') {
        Write-Host "   Existing client cert has a non-exportable private key. Recreating..." -ForegroundColor Yellow
        $clientCert | Remove-Item -Force

        # Check if the root cert has an accessible private key for signing.
        # If not, recreate it too (the VPN Gateway validates the root public
        # key which gets re-exported to .cer and passed as vpnRootCertData).
        if (-not $rootCert.HasPrivateKey) {
            Write-Host "   Root cert also lacks a private key. Recreating both certs..." -ForegroundColor Yellow
            $rootCert | Remove-Item -Force
            $rootCert = New-SelfSignedCertificate `
                -Type Custom `
                -Subject $rootCertSubject `
                -KeySpec Signature `
                -KeyExportPolicy Exportable `
                -KeyLength 2048 `
                -HashAlgorithm sha256 `
                -KeyUsageProperty Sign `
                -KeyUsage CertSign `
                -CertStoreLocation 'Cert:\CurrentUser\My' `
                -NotAfter (Get-Date).AddYears(3)
            Write-Ok "Root CA recreated: $($rootCert.Subject) (Thumbprint: $($rootCert.Thumbprint))"

            # Re-export root cert public key with the new cert
            $rootDer = $rootCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $rootCertBase64 = [Convert]::ToBase64String($rootDer)
            $rootPem = "-----BEGIN CERTIFICATE-----`r`n$rootCertBase64`r`n-----END CERTIFICATE-----"
            Set-Content -Path $RootCertPath -Value $rootPem -Encoding Ascii
            Write-Ok "Root cert re-exported: $RootCertPath"
        }

        $clientCert = New-SelfSignedCertificate `
            -Type Custom `
            -Subject $clientCertSubject `
            -KeySpec Signature `
            -KeyExportPolicy Exportable `
            -KeyLength 2048 `
            -HashAlgorithm sha256 `
            -Signer $rootCert `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -NotAfter (Get-Date).AddYears(3)
        Export-PfxCertificate -Cert $clientCert -FilePath $ClientPfxPath `
            -Password $pfxPwd -CryptoAlgorithmOption TripleDES_SHA1 | Out-Null
        Write-Ok "Client cert recreated with exportable key: $($clientCert.Subject) (Thumbprint: $($clientCert.Thumbprint))"
    } else {
        throw
    }
}
Write-Ok "Client PFX exported: $ClientPfxPath (password = admin password in Key Vault)"

# --- Step 3: Ensure root cert is in Trusted Root CAs ------------------------
$trustedStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
$trustedStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
$existingRoot = $trustedStore.Certificates | Where-Object { $_.Thumbprint -eq $rootCert.Thumbprint }
if ($existingRoot) {
    Write-Ok "Root cert already in Trusted Root (Thumbprint: $($rootCert.Thumbprint))"
} else {
    $trustedStore.Add($rootCert)
    Write-Ok "Root cert added to CurrentUser\\Trusted Root Certification Authorities"
}
$trustedStore.Close()

$VpnRootCertData = $rootCertBase64

# =============================================================================
# 4. Deploy
# =============================================================================
$tierDescription = switch ($DeploymentTier) {
    1 { "Tier 1: Core Networking + AD (DCs, Bastion, File Share Witness)" }
    2 { "Tier 2: + SQL Server VMs$(if($ColocateSqlBool){' (AOAG only — SQL colocated on MCM)'} else {' (5 VMs including AOAG at Site 2)'})" }
    3 { "Tier 3: Full Lab (Core + SQL + MCM servers)" }
}

# Build the --parameters array for VM names (must be array so each is a separate CLI argument)
$vmNameParams = @(
    "vmNameSqlCas=$($VmNames.SqlCas)"
    "vmNameSqlPrimA=$($VmNames.SqlPrimA)"
    "vmNameSqlPrimB=$($VmNames.SqlPrimB)"
    "vmNameSqlAoag1=$($VmNames.SqlAoag1)"
    "vmNameSqlAoag2=$($VmNames.SqlAoag2)"
    "vmNameCas=$($VmNames.Cas)"
    "vmNamePrimA=$($VmNames.PrimA)"
    "vmNamePrimB=$($VmNames.PrimB)"
    "vmNamePrimC=$($VmNames.PrimC)"
)
$colocateParam = if ($ColocateSqlBool) { 'colocateSql=true' } else { 'colocateSql=false' }
$joinDomainParam = if ($JoinDomainBool) { 'joinDomain=true' } else { 'joinDomain=false' }

# --- Detect existing private DNS zones -----------------------------------------
# If ArtifactsStorage (or another project) already created a privatelink DNS
# zone linked to the lab VNet, pass its resource ID so the Bicep modules reuse
# it instead of creating a conflicting duplicate (Azure blocks duplicate VNet
# links to different zones of the same name).
#
# Detection logic:
#   1. List all zones of the given name across the subscription
#   2. For each zone, check if it has a VNet link to the lab VNet
#   3. Use the first zone that has such a link
#   4. If no linked zone exists, let the Bicep template create one
# ---------------------------------------------------------------------------
$labVnetName = "$BaseName-vnet"
$labNetworkRg = "$BaseName-rg-network"
$labVnetId = az network vnet show -g $labNetworkRg -n $labVnetName --query id -o tsv 2>&1
if ($LASTEXITCODE -ne 0) { $labVnetId = '' } else { $labVnetId = $labVnetId.Trim() }

function Find-LinkedPrivateDnsZone {
    param([string]$ZoneName, [string]$VNetId)
    if ([string]::IsNullOrWhiteSpace($VNetId)) { return '' }

    # Get all zones with this name (returns resource ID + resource group)
    $zonesJson = az network private-dns zone list `
        --query "[?name=='$ZoneName'].{id:id, rg:resourceGroup}" -o json 2>&1
    if ($LASTEXITCODE -ne 0) { return '' }
    $zones = $null
    try { $zones = $zonesJson | ConvertFrom-Json } catch { return '' }
    if (-not $zones -or $zones.Count -eq 0) { return '' }

    foreach ($zone in $zones) {
        # Check if this zone has a VNet link pointing to the lab VNet
        $linksJson = az network private-dns link vnet list `
            --zone-name $ZoneName --resource-group $zone.rg `
            --query "[?virtualNetwork.id=='$VNetId'].id" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($linksJson)) {
            return $zone.id.Trim()
        }
    }
    return ''
}

# -- privatelink.file.core.windows.net (File Share Witness PE) --
$existingFileDnsZoneId = ''
Write-Step "Checking for existing privatelink.file.core.windows.net DNS zone linked to $labVnetName..."
if (-not [string]::IsNullOrWhiteSpace($labVnetId)) {
    $existingFileDnsZoneId = Find-LinkedPrivateDnsZone -ZoneName 'privatelink.file.core.windows.net' -VNetId $labVnetId
}
if (-not [string]::IsNullOrWhiteSpace($existingFileDnsZoneId)) {
    Write-Ok "Found linked zone: $existingFileDnsZoneId"
} else {
    Write-Ok "No linked zone found — Bicep will create one"
}

# -- privatelink.vaultcore.azure.net (Key Vault PE) --
$existingKvDnsZoneId = ''
Write-Step "Checking for existing privatelink.vaultcore.azure.net DNS zone linked to $labVnetName..."
if (-not [string]::IsNullOrWhiteSpace($labVnetId)) {
    $existingKvDnsZoneId = Find-LinkedPrivateDnsZone -ZoneName 'privatelink.vaultcore.azure.net' -VNetId $labVnetId
}
if (-not [string]::IsNullOrWhiteSpace($existingKvDnsZoneId)) {
    Write-Ok "Found linked zone: $existingKvDnsZoneId"
} else {
    Write-Ok "No linked zone found — Bicep will create one"
}

# Build the complete --parameters array (each key=value as a separate element
# so PowerShell passes them as individual arguments to az CLI).
# Each key=value is a separate array element so PowerShell passes them as
# individual arguments to az CLI.  The password charset is restricted to
# cmd.exe-safe characters, and base64 VPN cert data is inherently safe.
$deployParams = @(
    "baseName=$BaseName"
    "location=$Location"
    "deploymentTier=$DeploymentTier"
    "adminPassword=$AdminPassword"
    "domainName=$DomainName"
    "deployerObjectId=$DeployerObjectId"
    "kvPrincipalType=$KvPrincipalType"
    "vpnRootCertData=$VpnRootCertData"
    "enableEntraIntegration=$($EnableEntraBool.ToString().ToLower())"
    "entraIdDomain=$EntraIdDomain"
    "domainStrategy=$DomainStrategy"
    "entraConnectPlacement=$EntraConnectPlacement"
    "osDiskSku=$OsDiskSku"
    "existingFileDnsZoneId=$existingFileDnsZoneId"
    "existingKvDnsZoneId=$existingKvDnsZoneId"
    $colocateParam
    $joinDomainParam
) + $vmNameParams

Write-Header "Deployment Summary"
Write-Host "  Base Name       : $BaseName" -ForegroundColor White
Write-Host "  Location        : $Location" -ForegroundColor White
Write-Host "  Deployment Tier : $DeploymentTier — $tierDescription" -ForegroundColor White
Write-Host "  Incremental     : $IsIncremental" -ForegroundColor White
Write-Host "  SQL Colocated   : $ColocateSqlBool" -ForegroundColor White
Write-Host "  Domain Join     : $JoinDomainBool" -ForegroundColor White
Write-Host "  Domain Name     : $DomainName" -ForegroundColor White
Write-Host "  Entra ID        : $(if ($EnableEntraBool) {"ENABLED (domain: $EntraIdDomain, strategy: $DomainStrategy)"} else {'Disabled'})" -ForegroundColor White
if ($EnableEntraBool) {
    Write-Host "  Entra Connect   : $EntraConnectPlacement" -ForegroundColor White
}
Write-Host "  VM Timezone     : $VmTimeZone" -ForegroundColor White
Write-Host "  DNS Zone (file) : $(if ($existingFileDnsZoneId) {"Reusing: $existingFileDnsZoneId"} else {'New (will be created by Bicep)'})" -ForegroundColor White
Write-Host "  DNS Zone (vault): $(if ($existingKvDnsZoneId) {"Reusing: $existingKvDnsZoneId"} else {'New (will be created by Bicep)'})" -ForegroundColor White
Write-Host "  VPN Gateway     : P2S with self-signed certificate" -ForegroundColor White
Write-Host "  Admin Password  : $(if ($IsIncremental) {'(reused from Key Vault)'} else {'(auto-generated, stored in Key Vault)'})" -ForegroundColor White
Write-Host "  Template        : $templateFile" -ForegroundColor White

# =============================================================================
# 4a. Refresh Azure CLI token before deployment
# =============================================================================
# Interactive prompts (domain name, KV admin, cert generation) can take minutes.
# Refresh the token so the deployment call does not fail with invalid_grant.
Write-Step "Validating Azure CLI session before deployment..."
$tokenCheck = az account get-access-token --query "expiresOn" -o tsv 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Session expired or invalid. Re-authenticating..." -ForegroundColor Yellow
    az login | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Login failed. Run 'az login' manually and retry."
        exit 1
    }
    $account = az account show 2>&1 | ConvertFrom-Json
    Write-Ok "Re-authenticated as $($account.user.name)"
    # Restore subscription if it was explicitly set
    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId 2>&1 | Out-Null
    }
} else {
    Write-Ok "Session valid (token expires: $tokenCheck)"
}

if ($WhatIf) {
    Write-Header "What-If Preview (no resources will be created)"
    az deployment sub what-if `
        --location $Location `
        --template-file $templateFile `
        --parameters @deployParams

    Write-Host "`nWhat-If complete. No resources were modified." -ForegroundColor Cyan
    exit 0
}

Write-Header "Starting Deployment (Tier $DeploymentTier)"
$deploymentName = "$BaseName-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters @deployParams `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Deployment failed. Check the Azure portal or run:"
    Write-Host "   az deployment sub show --name $deploymentName --query properties.error" -ForegroundColor Gray
    exit 1
}

# =============================================================================
# 5a0. Post-Deployment: Set VM Timezone via RunCommand
# =============================================================================
# Azure ARM does not allow changing windowsConfiguration.timeZone on existing VMs,
# so we set the timezone via RunCommand (Set-TimeZone) which works on both new
# and existing VMs regardless of their current state.
# =============================================================================
if ($VmTimeZone -ne 'UTC') {
    Write-Header "Setting VM Timezone to $VmTimeZone"

    # Build list of VMs and their resource groups
    $vmTargets = @(
        @{ Name = "$BaseName-dc01"; RG = "$BaseName-rg-identity" }
        @{ Name = "$BaseName-dc02"; RG = "$BaseName-rg-identity" }
    )
    if ($EnableEntraBool -and $EntraConnectPlacement -eq 'dedicated') {
        $vmTargets += @{ Name = "$BaseName-aadcs"; RG = "$BaseName-rg-identity" }
    }
    if ($DeploymentTier -ge 2) {
        if (-not $ColocateSqlBool) {
            $vmTargets += @{ Name = $VmNames.SqlCas;  RG = "$BaseName-rg-main" }
            $vmTargets += @{ Name = $VmNames.SqlPrimA; RG = "$BaseName-rg-main" }
            $vmTargets += @{ Name = $VmNames.SqlPrimB; RG = "$BaseName-rg-site1" }
        }
        $vmTargets += @{ Name = $VmNames.SqlAoag1; RG = "$BaseName-rg-site2" }
        $vmTargets += @{ Name = $VmNames.SqlAoag2; RG = "$BaseName-rg-site2" }
    }
    if ($DeploymentTier -ge 3) {
        $vmTargets += @{ Name = $VmNames.Cas;   RG = "$BaseName-rg-main" }
        $vmTargets += @{ Name = $VmNames.PrimA; RG = "$BaseName-rg-main" }
        $vmTargets += @{ Name = $VmNames.PrimB; RG = "$BaseName-rg-site1" }
        $vmTargets += @{ Name = $VmNames.PrimC; RG = "$BaseName-rg-site2" }
    }

    $tzFailed = 0
    foreach ($vm in $vmTargets) {
        Write-Host "   Setting timezone on $($vm.Name)..." -ForegroundColor White -NoNewline
        $tzResult = az vm run-command invoke `
            --resource-group $vm.RG `
            --name $vm.Name `
            --command-id RunPowerShellScript `
            --scripts "Set-TimeZone -Id '$VmTimeZone'" `
            --query "value[0].message" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host " OK" -ForegroundColor Green
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            $tzFailed++
        }
    }
    if ($tzFailed -eq 0) {
        Write-Ok "All VMs set to $VmTimeZone"
    } else {
        Write-Host "   WARNING: $tzFailed VM(s) failed timezone update. You can set manually via RDP: Set-TimeZone -Id '$VmTimeZone'" -ForegroundColor Yellow
    }
} else {
    Write-Ok "VM Timezone: UTC (default — no change needed)"
}

# =============================================================================
# 5b. Post-Deployment: Add GRP-MCMAdmins to Local Administrators on MCM VMs
# =============================================================================
# After domain join, add the domain group GRP-MCMAdmins to the Local
# Administrators group on each MCM server so mcm-admin (and any future members)
# have local admin rights without needing Domain Admins membership.
# =============================================================================
if ($DeploymentTier -ge 3 -and $JoinDomainBool) {
    Write-Header "Adding GRP-MCMAdmins to Local Administrators on MCM VMs"

    $netbios = $DomainName.Split('.')[0].ToUpper()
    $mcmVms = @(
        @{ Name = $VmNames.Cas;   RG = "$BaseName-rg-main" }
        @{ Name = $VmNames.PrimA; RG = "$BaseName-rg-main" }
        @{ Name = $VmNames.PrimB; RG = "$BaseName-rg-site1" }
        @{ Name = $VmNames.PrimC; RG = "$BaseName-rg-site2" }
    )

    $laFailed = 0
    foreach ($vm in $mcmVms) {
        Write-Host "   Adding GRP-MCMAdmins to Local Admins on $($vm.Name)..." -ForegroundColor White -NoNewline
        $laResult = az vm run-command invoke `
            --resource-group $vm.RG `
            --name $vm.Name `
            --command-id RunPowerShellScript `
            --scripts "Add-LocalGroupMember -Group 'Administrators' -Member '$netbios\GRP-MCMAdmins' -ErrorAction SilentlyContinue; Get-LocalGroupMember -Group 'Administrators' | Select-Object -ExpandProperty Name" `
            --query "value[0].message" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host " OK" -ForegroundColor Green
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            $laFailed++
        }
    }
    if ($laFailed -eq 0) {
        Write-Ok "GRP-MCMAdmins added to Local Administrators on all MCM VMs"
    } else {
        Write-Host "   WARNING: $laFailed VM(s) failed. Add manually: Add-LocalGroupMember -Group 'Administrators' -Member '$netbios\GRP-MCMAdmins'" -ForegroundColor Yellow
    }
}

# =============================================================================
# 5. Post-Deployment Summary
# =============================================================================
Write-Header "Deployment Complete!"
Write-Host ""
Write-Host "  Resource Groups created:" -ForegroundColor White
Write-Host "    - $BaseName-rg-network    (VNet, NSGs, Bastion, VPN Gateway)" -ForegroundColor Gray
Write-Host "    - $BaseName-rg-identity   (DCs, Key Vault, File Share Witness)" -ForegroundColor Gray
if ($DeploymentTier -ge 2) {
    $mainContents = @()
    if (-not $ColocateSqlBool) { $mainContents += "$($VmNames.SqlCas)", "$($VmNames.SqlPrimA)" }
    if ($DeploymentTier -ge 3) { $mainContents += "$($VmNames.Cas)", "$($VmNames.PrimA)" }
    $site1Contents = @()
    if (-not $ColocateSqlBool) { $site1Contents += "$($VmNames.SqlPrimB)" }
    if ($DeploymentTier -ge 3) { $site1Contents += "$($VmNames.PrimB)" }
    $site2Contents = @("$($VmNames.SqlAoag1)", "$($VmNames.SqlAoag2)", 'ILB')
    if ($DeploymentTier -ge 3) { $site2Contents += "$($VmNames.PrimC)" }

    Write-Host "    - $BaseName-rg-main       ($($mainContents -join ', '))" -ForegroundColor Gray
    Write-Host "    - $BaseName-rg-site1      ($($site1Contents -join ', '))" -ForegroundColor Gray
    Write-Host "    - $BaseName-rg-site2      ($($site2Contents -join ', '))" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Deployed VMs:" -ForegroundColor Cyan
Write-Host "    Identity : $BaseName-dc01, $BaseName-dc02" -ForegroundColor Gray
if ($EnableEntraBool) {
    if ($EntraConnectPlacement -eq 'dedicated') {
        Write-Host "    EntraSync: $BaseName-aadcs (Entra Connect Sync)" -ForegroundColor Gray
    } else {
        Write-Host "    EntraSync: Installed on $BaseName-dc02" -ForegroundColor Gray
    }
    Write-Host "    Mgmt     : Deploy separately -> .\deploy-mgmt.ps1 -BaseName $BaseName" -ForegroundColor Yellow
}
if ($DeploymentTier -ge 2) {
    if (-not $ColocateSqlBool) {
        Write-Host "    SQL      : $($VmNames.SqlCas), $($VmNames.SqlPrimA), $($VmNames.SqlPrimB)" -ForegroundColor Gray
    }
    Write-Host "    SQL AOAG : $($VmNames.SqlAoag1), $($VmNames.SqlAoag2)" -ForegroundColor Gray
}
if ($DeploymentTier -ge 3) {
    $mcmLabel = if ($ColocateSqlBool) { 'MCM+SQL' } else { 'MCM' }
    Write-Host "    $($mcmLabel.PadRight(8)) : $($VmNames.Cas), $($VmNames.PrimA), $($VmNames.PrimB), $($VmNames.PrimC)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Cyan
Write-Host "  1) Retrieve admin password from Key Vault (requires VPN):" -ForegroundColor White
Write-Host "     az keyvault secret show --vault-name <keyvault-name> --name vm-admin-password --query value -o tsv" -ForegroundColor Gray
Write-Host "     (Find your KV name: az keyvault list --resource-group $BaseName-rg-identity --query [].name -o tsv)" -ForegroundColor Gray
Write-Host "     NOTE: Key Vault has no public endpoint. You must be on VPN to access secrets." -ForegroundColor Yellow
Write-Host "  2) Connect via Bastion: Portal > $BaseName-bastion > Connect to VM" -ForegroundColor White
Write-Host "  3) Connect via VPN:" -ForegroundColor White
Write-Host "     a) Download VPN client: Portal > $BaseName-vpngw > Point-to-site > Download VPN client" -ForegroundColor Gray
Write-Host "     b) Client cert is already installed (CurrentUser\My)" -ForegroundColor Gray
Write-Host "     c) Run the downloaded VPN client configuration" -ForegroundColor Gray
Write-Host "     d) Connect using Windows VPN settings" -ForegroundColor Gray
Write-Host "     NOTE: VPN Gateway takes 25-45 min to provision. It may still be deploying." -ForegroundColor Yellow
Write-Host "  4) AD Domain Services (automated):" -ForegroundColor White
Write-Host "     - DC01 promoted as first DC in $DomainName" -ForegroundColor Gray
Write-Host "     - DC02 promoted as replica DC" -ForegroundColor Gray
Write-Host "     - OUs, security groups, service accounts, and gMSA created" -ForegroundColor Gray
Write-Host "     - Admin accounts: lab-admin (delegated OU admin), mcm-admin, sql-admin" -ForegroundColor Gray
Write-Host "     - GRP-DomainAdmins-Lab created empty (populate manually)" -ForegroundColor Gray
Write-Host "     - VNet DNS set to DC IPs (10.0.1.4, 10.0.1.5)" -ForegroundColor Gray
if ($JoinDomainBool) {
    Write-Host "  5) Domain join (automated):" -ForegroundColor White
    Write-Host "     - SQL and MCM VMs auto-joined to $DomainName using svc-domjoin" -ForegroundColor Gray
    Write-Host "     - SQL VMs placed in OU=SQL Servers,OU=Lab Servers" -ForegroundColor Gray
    Write-Host "     - MCM VMs placed in OU=App Servers,OU=Lab Servers" -ForegroundColor Gray
    Write-Host "     - GRP-MCMAdmins added to Local Administrators on MCM VMs" -ForegroundColor Gray
} else {
    Write-Host "  5) Domain-join remaining servers (SQL, MCM) — MANUAL (skipped during deployment)" -ForegroundColor Yellow
}
if ($EnableEntraBool) {
    Write-Host ""
    Write-Host "  ** ENTRA ID INTEGRATION (manual post-deployment steps) **" -ForegroundColor Cyan
    $entraConnectVm = if ($EntraConnectPlacement -eq 'dedicated') { "$BaseName-aadcs" } else { "$BaseName-dc02" }
    Write-Host "  A) Complete Entra Connect wizard on $entraConnectVm :" -ForegroundColor White
    Write-Host "     1. RDP/Bastion into $entraConnectVm" -ForegroundColor Gray
    Write-Host "     2. Launch 'Azure AD Connect' from desktop" -ForegroundColor Gray
    Write-Host "     3. Accept license terms, click Continue" -ForegroundColor Gray
    Write-Host "     4. Click 'Customize' (not Express Settings) for OU filtering" -ForegroundColor Gray
    Write-Host "     5. Click 'Install' (no optional prereqs needed for lab)" -ForegroundColor Gray
    Write-Host "     6. User Sign-in: select 'Password Hash Synchronization', click Next" -ForegroundColor Gray
    Write-Host "     7. Connect to Entra ID: sign in with Global Administrator credentials" -ForegroundColor Gray
    Write-Host "     8. Connect Directories: Forest = $DomainName, click 'Add Directory'" -ForegroundColor Gray
    Write-Host "        -> Select 'Create new AD account', enter Enterprise Admin creds:" -ForegroundColor Gray
    Write-Host "           Username: $DomainName\labadmin  |  Password: (from Key Vault)" -ForegroundColor Gray
    Write-Host "     9. Azure AD sign-in: verify UPN suffix is configured, click Next" -ForegroundColor Gray
    Write-Host "    10. Domain/OU filtering: select 'Sync selected domains and OUs'" -ForegroundColor Gray
    Write-Host "        -> Uncheck all, then check ONLY:" -ForegroundColor Gray
    Write-Host "           [x] Lab Accounts  [x] Lab Groups  [x] Lab Servers" -ForegroundColor Gray
    Write-Host "    11. Uniquely identifying users: keep defaults, click Next" -ForegroundColor Gray
    Write-Host "    12. Filter users/devices: keep 'Synchronize all', click Next" -ForegroundColor Gray
    Write-Host "    13. Optional features: 'Password hash synchronization' is pre-checked" -ForegroundColor Gray
    Write-Host "        -> No additional features needed for the lab" -ForegroundColor Gray
    Write-Host "    14. Click 'Install' to start configuration and initial sync" -ForegroundColor Gray
    Write-Host "    15. Wait for sync to complete (2-5 min), then verify in Entra ID > Users" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Gray
    Write-Host "     OPTIONAL: Hybrid Entra ID Join (after initial sync):" -ForegroundColor Yellow
    Write-Host "     -> Re-open Entra Connect > Configure > Device options" -ForegroundColor Gray
    Write-Host "     -> Select 'Configure Hybrid Microsoft Entra ID join'" -ForegroundColor Gray
    Write-Host "     -> Check 'Windows 10 or later domain-joined devices'" -ForegroundColor Gray
    Write-Host "     -> Select your forest, configure SCP (Service Connection Point)" -ForegroundColor Gray
    Write-Host "     -> This allows domain-joined VMs to also register in Entra ID" -ForegroundColor Gray
    Write-Host "  B) Deploy Management VM (pure Entra ID joined):" -ForegroundColor White
    Write-Host "     Run AFTER the lab deployment completes successfully:" -ForegroundColor Yellow
    Write-Host "       .\deploy-mgmt.ps1 -BaseName $BaseName -Location $Location" -ForegroundColor Cyan
    Write-Host "     This deploys $BaseName-mgmt with Entra ID login, RSAT, Az CLI" -ForegroundColor Gray
    Write-Host "     lab-admin has delegated control over Lab OUs (not Domain Admin)" -ForegroundColor Gray
    Write-Host "     To manage AD: runas /netonly /user:$DomainName\lab-admin mmc.exe" -ForegroundColor Gray
    Write-Host "  C) Artifacts Storage (Azure Files share):" -ForegroundColor White
    Write-Host "     Deploy from: .\..\ArtifactsStorage\deploy.ps1" -ForegroundColor Gray
    Write-Host "     Option 1 - AD DS (recommended): all domain-joined VMs can net use" -ForegroundColor Gray
    Write-Host "       .\deploy.ps1 -NamePrefix artifacts -Location $Location -LabBaseName $BaseName" -ForegroundColor Cyan
    Write-Host "     Option 2 - Entra Kerberos: requires Hybrid Entra Join + synced user" -ForegroundColor Gray
    Write-Host "       .\deploy.ps1 -NamePrefix artifacts -Location $Location -LabBaseName $BaseName -EnableEntraKerberos" -ForegroundColor Cyan
    Write-Host "     Mgmt VM + VPN: use az storage file --auth-mode login (either mode)" -ForegroundColor Gray
}
if ($DeploymentTier -ge 2) {
    if ($ColocateSqlBool) {
        Write-Host "  6) Install SQL Server on MCM VMs: $($VmNames.Cas), $($VmNames.PrimA), $($VmNames.PrimB)" -ForegroundColor White
    } else {
        Write-Host "  6) Install SQL Server on: $($VmNames.SqlCas), $($VmNames.SqlPrimA), $($VmNames.SqlPrimB)" -ForegroundColor White
    }
    Write-Host "  7) Install SQL Server on AOAG nodes: $($VmNames.SqlAoag1), $($VmNames.SqlAoag2)" -ForegroundColor White
    Write-Host "  8) Register File Share Witness in AD (run separately after deployment):" -ForegroundColor White
    Write-Host "       .\Register-WitnessStorage.ps1 -BaseName $BaseName" -ForegroundColor Cyan
    Write-Host "     Then configure WSFC quorum + create AOAG on Site 2 SQL nodes" -ForegroundColor Gray
    Write-Host "  9) Create AG Listener using ILB IP 10.0.40.10 (probe port 59999)" -ForegroundColor White
}
if ($DeploymentTier -ge 3) {
    Write-Host " 10) Install MCM workloads on CAS and primary servers" -ForegroundColor White
    Write-Host "     - $($VmNames.Cas): CAS (Main site)" -ForegroundColor Gray
    Write-Host "     - $($VmNames.PrimA): Child Primary A (Main site)" -ForegroundColor Gray
    Write-Host "     - $($VmNames.PrimB): Child Primary B (Site 1)" -ForegroundColor Gray
    Write-Host "     - $($VmNames.PrimC): Child Primary C (Site 2, uses AOAG listener)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  To list deployed resources:" -ForegroundColor Gray
Write-Host "    az group list --tag env=lab --output table" -ForegroundColor Gray
Write-Host "    az vm list --query ""[?tags.project=='azure-lab'].[name,resourceGroup,location]"" -o table" -ForegroundColor Gray
Write-Host ""

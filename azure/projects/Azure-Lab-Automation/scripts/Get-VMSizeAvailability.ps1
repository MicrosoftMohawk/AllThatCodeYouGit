<#
.SYNOPSIS
    Checks Azure VM SKU availability in a specified region.

.DESCRIPTION
    Queries Azure for available VM sizes in a given region, showing which SKUs
    are available, restricted, or not available for the current subscription.
    Can filter by size family/pattern and optionally suggest alternatives when
    a specific SKU is restricted.

.PARAMETER Location
    Azure region to check (e.g., 'eastus2', 'westus3'). Defaults to 'eastus2'.

.PARAMETER SizeFilter
    Optional filter pattern for VM size names. Supports wildcards.
    Examples: 'Standard_D*s_v5', 'Standard_D2*', 'Standard_E*'

.PARAMETER ShowAlternatives
    When specified with -SizeFilter, shows alternative available SKUs in the
    same family if the filtered SKU is restricted.

.PARAMETER LabSizes
    Checks availability for all VM sizes used by the Azure-Lab-Automation
    deployment (Standard_D2s_v5, Standard_D4s_v5, Standard_D8s_v5).

.EXAMPLE
    .\Get-VMSizeAvailability.ps1 -Location eastus2 -LabSizes
    Checks all lab deployment VM sizes in eastus2.

.EXAMPLE
    .\Get-VMSizeAvailability.ps1 -Location westus3 -SizeFilter 'Standard_D4s*'
    Shows all D4s variants available in westus3.

.EXAMPLE
    .\Get-VMSizeAvailability.ps1 -Location eastus2 -SizeFilter 'Standard_D2s_v5' -ShowAlternatives
    Checks if Standard_D2s_v5 is available and suggests alternatives if not.
#>

[CmdletBinding(DefaultParameterSetName = 'Filter')]
param(
    [Parameter()]
    [string]$Location = 'eastus2',

    [Parameter(ParameterSetName = 'Filter')]
    [string]$SizeFilter,

    [Parameter(ParameterSetName = 'Filter')]
    [switch]$ShowAlternatives,

    [Parameter(ParameterSetName = 'Lab')]
    [switch]$LabSizes
)

$ErrorActionPreference = 'Stop'

# Verify Azure CLI is available and logged in
try {
    $account = az account show 2>&1 | ConvertFrom-Json
    if (-not $account.id) { throw }
    Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan
}
catch {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first."
    return
}

Write-Host "`nQuerying VM SKU availability in '$Location'..." -ForegroundColor Cyan

# Fetch all VM SKUs for the region
$allSkus = az vm list-skus --location $Location --resource-type virtualMachines --all 2>$null | ConvertFrom-Json

if (-not $allSkus -or $allSkus.Count -eq 0) {
    Write-Error "No VM SKUs found for location '$Location'. Verify the region name is correct."
    return
}

# Build a results table with availability status
function Get-SkuStatus {
    param([array]$Skus)

    $results = foreach ($sku in $Skus) {
        $restrictions = $sku.restrictions
        $status = 'Available'
        $reason = ''

        if ($restrictions -and $restrictions.Count -gt 0) {
            foreach ($r in $restrictions) {
                if ($r.reasonCode -eq 'NotAvailableForSubscription') {
                    $status = 'Not Available (Subscription)'
                    $reason = $r.reasonCode
                }
                elseif ($r.reasonCode -eq 'CapacityRestricted' -or $r.type -eq 'Location') {
                    $status = 'Capacity Restricted'
                    $reason = $r.reasonCode
                }
                else {
                    $status = "Restricted ($($r.reasonCode))"
                    $reason = $r.reasonCode
                }
            }
        }

        $zones = if ($sku.locationInfo -and $sku.locationInfo[0].zones) {
            ($sku.locationInfo[0].zones | Sort-Object) -join ', '
        } else { 'None' }

        $caps = @{}
        if ($sku.capabilities) {
            foreach ($c in $sku.capabilities) {
                $caps[$c.name] = $c.value
            }
        }

        [PSCustomObject]@{
            Name     = $sku.name
            Status   = $status
            vCPUs    = $caps['vCPUs']
            MemoryGB = $caps['MemoryGB']
            Zones    = $zones
        }
    }

    return $results
}

# Lab mode: check all sizes used by the deployment
if ($LabSizes) {
    $labSkuNames = @('Standard_D2s_v6', 'Standard_D4s_v6', 'Standard_D8s_v6')
    $labRoles = @{
        'Standard_D2s_v6' = 'Domain Controllers / Mgmt (sizeDC, sizeManagement)'
        'Standard_D4s_v6' = 'App Servers / SQL (sizeApp, sizeSQL)'
        'Standard_D8s_v6' = 'Colocated MCM+SQL (sizeAppColocated)'
    }

    Write-Host "`n=== Lab Deployment VM Size Availability ===" -ForegroundColor Yellow
    Write-Host "Region: $Location`n"

    foreach ($skuName in $labSkuNames) {
        $sku = $allSkus | Where-Object { $_.name -eq $skuName }
        $role = $labRoles[$skuName]

        if (-not $sku) {
            Write-Host "  $skuName  ($role)" -ForegroundColor Red
            Write-Host "    Status: NOT AVAILABLE in this region" -ForegroundColor Red
        }
        else {
            $result = (Get-SkuStatus -Skus @($sku))[0]
            $color = if ($result.Status -eq 'Available') { 'Green' } else { 'Red' }
            Write-Host "  $skuName  ($role)" -ForegroundColor $color
            Write-Host "    Status: $($result.Status)" -ForegroundColor $color
            Write-Host "    vCPUs: $($result.vCPUs)  Memory: $($result.MemoryGB) GB  Zones: $($result.Zones)"
        }

        # Always show alternatives for lab sizes
        $family = $skuName -replace '_v\d+$', ''
        $alternatives = $allSkus | Where-Object {
            $_.name -like "${family}_v*" -and $_.name -ne $skuName
        }
        $altResults = Get-SkuStatus -Skus $alternatives | Where-Object { $_.Status -eq 'Available' } | Sort-Object Name
        if ($altResults) {
            Write-Host "    Alternatives:" -ForegroundColor Cyan
            foreach ($alt in $altResults) {
                Write-Host "      $($alt.Name)  (vCPUs: $($alt.vCPUs), Mem: $($alt.MemoryGB) GB, Zones: $($alt.Zones))" -ForegroundColor Green
            }
        }
        Write-Host ""
    }

    # Summary recommendation
    $allUnavailable = $true
    foreach ($skuName in $labSkuNames) {
        $sku = $allSkus | Where-Object { $_.name -eq $skuName }
        if ($sku) {
            $result = (Get-SkuStatus -Skus @($sku))[0]
            if ($result.Status -eq 'Available') { $allUnavailable = $false }
        }
    }

    if ($allUnavailable) {
        Write-Host "=== RECOMMENDATION ===" -ForegroundColor Yellow
        Write-Host "None of the default v6 sizes are available in '$Location'." -ForegroundColor Red
        Write-Host "Update your deployment parameters to use available alternatives:" -ForegroundColor Yellow
        Write-Host "  In main.bicepparam or via --parameters overrides:" -ForegroundColor White

        foreach ($skuName in $labSkuNames) {
            $family = $skuName -replace '_v\d+$', ''
            $alt = $allSkus | Where-Object {
                $_.name -like "${family}_v*" -and $_.name -ne $skuName
            }
            $bestAlt = (Get-SkuStatus -Skus $alt | Where-Object { $_.Status -eq 'Available' } | Sort-Object Name | Select-Object -First 1)
            if ($bestAlt) {
                $paramName = switch -Wildcard ($skuName) {
                    '*D2s*' { 'sizeDC / sizeManagement' }
                    '*D4s*' { 'sizeApp / sizeSQL' }
                    '*D8s*' { 'sizeAppColocated' }
                }
                Write-Host "    $paramName = '$($bestAlt.Name)'  (was '$skuName')" -ForegroundColor Green
            }
        }
    }

    return
}

# Filter mode
if ($SizeFilter) {
    $filtered = $allSkus | Where-Object { $_.name -like $SizeFilter }

    if (-not $filtered -or $filtered.Count -eq 0) {
        Write-Host "`nNo SKUs matching '$SizeFilter' found in '$Location'." -ForegroundColor Red

        if ($ShowAlternatives) {
            # Try to find the family and show alternatives
            $family = $SizeFilter -replace '[*?]', '' -replace '_v\d+$', ''
            $alternatives = $allSkus | Where-Object { $_.name -like "${family}*" }
            if ($alternatives) {
                Write-Host "`nAlternative sizes in the '$family' family:" -ForegroundColor Yellow
                $altResults = Get-SkuStatus -Skus $alternatives |
                    Where-Object { $_.Status -eq 'Available' } |
                    Sort-Object Name
                $altResults | Format-Table -AutoSize
            }
        }
        return
    }

    $results = Get-SkuStatus -Skus $filtered | Sort-Object Name

    Write-Host "`nResults for '$SizeFilter' in '$Location':" -ForegroundColor Yellow
    $results | Format-Table -AutoSize

    if ($ShowAlternatives) {
        $unavailable = $results | Where-Object { $_.Status -ne 'Available' }
        if ($unavailable) {
            foreach ($u in $unavailable) {
                $family = $u.Name -replace '_v\d+$', ''
                $alternatives = $allSkus | Where-Object {
                    $_.name -like "${family}_v*" -and $_.name -ne $u.Name
                }
                $altResults = Get-SkuStatus -Skus $alternatives |
                    Where-Object { $_.Status -eq 'Available' } |
                    Sort-Object Name
                if ($altResults) {
                    Write-Host "Alternatives for '$($u.Name)':" -ForegroundColor Yellow
                    $altResults | Format-Table -AutoSize
                }
            }
        }
    }
}
else {
    # No filter — show summary of all available sizes
    $results = Get-SkuStatus -Skus $allSkus |
        Where-Object { $_.Status -eq 'Available' } |
        Sort-Object Name

    Write-Host "`nAvailable VM sizes in '$Location': $($results.Count) of $($allSkus.Count) total" -ForegroundColor Yellow
    $results | Format-Table -AutoSize
}

# ============================================================================
# Regulatory Compliance Custom Initiative Deployment Script
# Purpose: Export built-in compliance initiatives (NIST, CIS, HIPAA, PCI DSS,
#          FedRAMP, etc.), transform to custom policy type, create/update the
#          initiative definition, and optionally assign it.
# ============================================================================
# Azure Portal cannot export built-in policy initiative definitions.
# This script uses Az PowerShell to export, transform PascalCase -> camelCase,
# strip built-in-only fields, and upload as a Custom initiative that can be
# attached in Microsoft Defender for Cloud.
# ============================================================================

<#
.SYNOPSIS
    Exports a built-in Azure regulatory compliance initiative and deploys it as
    a custom initiative definition to a subscription or management group.

.DESCRIPTION
    This script:
    1. Authenticates to Azure (or reuses an existing session)
    2. Lets the user select a subscription
    3. Retrieves all built-in compliance policy initiatives and lets the user
       search/filter and select one (NIST 800-53 R5, CIS, HIPAA, PCI DSS, etc.)
    4. Exports the built-in initiative to a pristine JSON backup
    5. Transforms the export from built-in -> custom format:
       - Strips built-in-only fields (Id, Name, PolicyType, SystemData*, Type, Version, Versions)
       - Converts PascalCase property names to camelCase for ARM REST API compatibility
       - Sets policyType to "Custom"
    6. Saves the transformed JSON for offline editing
    7. Creates (or updates) the custom initiative definition at the chosen scope
    8. Optionally assigns the initiative to the subscription or management group

.PARAMETER SubscriptionId
    Azure Subscription ID. If omitted, the script prompts interactively.

.PARAMETER ManagementGroupId
    Target Management Group name/ID. If omitted, the script prompts for scope.

.PARAMETER InitiativeName
    Name for the custom initiative (max 64 chars, alphanumeric/hyphens/underscores).
    Defaults to a sanitized version of the source initiative display name.

.PARAMETER SearchFilter
    Text to filter built-in compliance initiatives (e.g. "NIST", "CIS", "HIPAA").
    If omitted, the script prompts interactively.

.PARAMETER JsonOutputPath
    Directory for exported JSON files. Defaults to $PSScriptRoot.

.PARAMETER SkipAssignment
    If set, skips the optional assignment prompt after creating the initiative.

.PARAMETER SkipExport
    If set, skips the export step and uses an existing custom JSON file.

.EXAMPLE
    .\Deploy-CustomNIST-Initiative.ps1
    # Interactive mode: prompts for everything

.EXAMPLE
    .\Deploy-CustomNIST-Initiative.ps1 -SearchFilter "NIST" -InitiativeName "NIST-R5-Custom" -SkipAssignment
    # Semi-automated: searches for NIST, still prompts for subscription/scope

.NOTES
    Requires: Az.Resources, Az.PolicyInsights modules
    Minimum: PowerShell 5.1 / PowerShell 7+
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ManagementGroupId,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')]
    [string]$InitiativeName,

    [Parameter()]
    [string]$SearchFilter,

    [Parameter()]
    [string]$JsonOutputPath,

    [Parameter()]
    [switch]$SkipAssignment,

    [Parameter()]
    [switch]$SkipExport
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

#region Helper Functions

function Read-ValidatedInt {
    <#
    .SYNOPSIS
        Prompts the user for an integer within a range and validates input.
    #>
    param(
        [string]$Prompt,
        [int]$Min = 0,
        [int]$Max
    )
    while ($true) {
        $input_val = Read-Host $Prompt
        $parsed = 0
        if ([int]::TryParse($input_val, [ref]$parsed)) {
            if ($parsed -ge $Min -and $parsed -le $Max) {
                return $parsed
            }
        }
        Write-Host "  Invalid input. Please enter a number between $Min and $Max." -ForegroundColor Red
    }
}

function ConvertTo-CamelCase {
    <#
    .SYNOPSIS
        Converts "PascalCase" to "camelCase".
    #>
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name) -or $Name.Length -eq 0) { return $Name }
    return $Name.Substring(0, 1).ToLower() + $Name.Substring(1)
}

function Convert-PolicyDefinitionItem {
    <#
    .SYNOPSIS
        Transforms a single policy definition entry from PowerShell PascalCase
        to ARM camelCase format.
    #>
    param([PSObject]$Item)

    $transformed = [ordered]@{}

    # Map known fields: PowerShell PascalCase export name -> ARM camelCase name
    # Note: PS hashtables are case-insensitive, so camelCase inputs also match.
    # Only include the PascalCase key; camelCase lookups resolve automatically.
    $fieldMap = @{
        'PolicyDefinitionId' = 'policyDefinitionId'
        'Id'                 = 'policyDefinitionReferenceId'
        'GroupName'          = 'groupNames'
        'Parameter'          = 'parameters'
        'DefinitionVersion'  = 'definitionVersion'
    }

    # NOTE: definitionVersion is intentionally KEPT - it pins each policy
    # to a compatible version. Without it, Azure resolves the latest version
    # which may have removed/renamed parameters (e.g. minPort/maxPort).

    foreach ($prop in $Item.PSObject.Properties) {

        $targetName = if ($fieldMap.ContainsKey($prop.Name)) {
            $fieldMap[$prop.Name]
        } else {
            ConvertTo-CamelCase $prop.Name
        }

        $transformed[$targetName] = $prop.Value
    }

    return [PSCustomObject]$transformed
}

function Convert-PolicyDefinitionGroupItem {
    <#
    .SYNOPSIS
        Transforms a policy definition group entry from PascalCase to camelCase.
    #>
    param([PSObject]$Item)

    $transformed = [ordered]@{}

    # PS hashtables are case-insensitive, so PascalCase keys also catch camelCase.
    $fieldMap = @{
        'Name'                 = 'name'
        'DisplayName'          = 'displayName'
        'Category'             = 'category'
        'Description'          = 'description'
        'AdditionalMetadataId' = 'additionalMetadataId'
    }

    foreach ($prop in $Item.PSObject.Properties) {
        $targetName = if ($fieldMap.ContainsKey($prop.Name)) {
            $fieldMap[$prop.Name]
        } else {
            ConvertTo-CamelCase $prop.Name
        }
        $transformed[$targetName] = $prop.Value
    }

    return [PSCustomObject]$transformed
}

function Convert-BuiltInToCustomJson {
    <#
    .SYNOPSIS
        Takes a raw PowerShell-exported initiative object (or parsed JSON) and
        produces a clean ARM-compatible custom initiative JSON structure.

    .DESCRIPTION
        - Wraps output in ARM REST API format with 'properties' container
        - Sets policyType to "Custom" inside properties
        - Preserves definitionVersion to pin policies to compatible versions
        - Converts PascalCase -> camelCase property names
        - Handles both PowerShell flat format and Azure CLI/REST API nested format
    #>
    param(
        [Parameter(Mandatory)]
        [PSObject]$SourceObject
    )

    # Detect format (PowerShell flat vs Azure CLI nested)
    if ($SourceObject.properties) {
        # Azure CLI / REST API nested format
        $src = $SourceObject.properties
        $srcDisplayName     = $src.displayName
        $srcDescription     = $src.description
        $srcMetadata        = $src.metadata
        $srcParameters      = $src.parameters
        $srcPolicyDefs      = $src.policyDefinitions
        $srcPolicyGroups    = $src.policyDefinitionGroups
    } else {
        # PowerShell cmdlet flat format
        $srcDisplayName     = $SourceObject.DisplayName
        $srcDescription     = $SourceObject.Description
        $srcMetadata        = $SourceObject.Metadata
        $srcParameters      = $SourceObject.Parameter
        $srcPolicyDefs      = $SourceObject.PolicyDefinition
        $srcPolicyGroups    = $SourceObject.PolicyDefinitionGroup
    }

    # Transform policy definitions (PascalCase -> camelCase)
    $transformedPolicyDefs = @()
    if ($srcPolicyDefs) {
        foreach ($pd in $srcPolicyDefs) {
            $transformedPolicyDefs += Convert-PolicyDefinitionItem -Item $pd
        }
    }

    # Transform policy definition groups
    $transformedGroups = @()
    if ($srcPolicyGroups) {
        foreach ($grp in $srcPolicyGroups) {
            $transformedGroups += Convert-PolicyDefinitionGroupItem -Item $grp
        }
    }

    # Extract version and versions from source
    $srcVersion  = $null
    $srcVersions = $null
    if ($SourceObject.properties) {
        $srcVersion  = $src.version
        $srcVersions = $src.versions
    } elseif ($SourceObject.Version) {
        $srcVersion  = $SourceObject.Version
    }

    # Build the properties container (ARM REST API format)
    $properties = [ordered]@{
        displayName            = $srcDisplayName
        policyType             = "Custom"
        description            = $srcDescription
        metadata               = if ($srcMetadata) { $srcMetadata } else { @{} }
    }
    if ($srcVersion)  { $properties['version']  = $srcVersion }
    $properties['policyDefinitionGroups'] = $transformedGroups
    $properties['parameters']             = if ($srcParameters) { $srcParameters } else { @{} }
    $properties['policyDefinitions']      = $transformedPolicyDefs
    if ($srcVersions) { $properties['versions'] = $srcVersions }

    # Build the full ARM-format object with properties wrapper
    $customInitiative = [ordered]@{
        properties = [PSCustomObject]$properties
    }

    # Preserve top-level id and name from source (informational)
    if ($SourceObject.id)   { $customInitiative['id']   = $SourceObject.id }
    if ($SourceObject.name) { $customInitiative['name'] = $SourceObject.name }

    return [PSCustomObject]$customInitiative
}

function Repair-EffectParameterCasing {
    <#
    .SYNOPSIS
        Normalizes Azure Policy effect parameter values to correct PascalCase.

    .DESCRIPTION
        Built-in initiatives may contain lowercase effect defaults (e.g. 'audit')
        that are accepted for BuiltIn types but rejected for Custom initiatives.
        This function normalizes all known effect values to their correct casing.
    #>
    param(
        [Parameter(Mandatory)]
        [PSObject]$InitiativeObject
    )

    # Canonical PascalCase for all known Azure Policy effects
    $effectNormalizer = @{
        'audit'             = 'Audit'
        'deny'              = 'Deny'
        'disabled'          = 'Disabled'
        'deployifnotexists' = 'DeployIfNotExists'
        'modify'            = 'Modify'
        'auditifnotexists'  = 'AuditIfNotExists'
        'append'            = 'Append'
        'manual'            = 'Manual'
        'denyaction'        = 'DenyAction'
    }

    $fixCount = 0

    # Fix initiative-level parameters
    if ($InitiativeObject.parameters) {
        $paramObj = $InitiativeObject.parameters
        $paramNames = if ($paramObj -is [hashtable]) {
            $paramObj.Keys
        } else {
            ($paramObj | Get-Member -MemberType Properties -ErrorAction SilentlyContinue).Name
        }

        foreach ($pName in $paramNames) {
            $paramDef = if ($paramObj -is [hashtable]) { $paramObj[$pName] } else { $paramObj.$pName }
            if (-not $paramDef) { continue }

            # Fix defaultValue
            $defaultVal = $null
            if ($paramDef -is [hashtable] -and $paramDef.ContainsKey('defaultValue')) {
                $defaultVal = $paramDef['defaultValue']
            } elseif ($paramDef.PSObject.Properties['defaultValue']) {
                $defaultVal = $paramDef.defaultValue
            }

            if ($defaultVal -is [string] -and $effectNormalizer.ContainsKey($defaultVal.ToLower())) {
                $corrected = $effectNormalizer[$defaultVal.ToLower()]
                if ($defaultVal -cne $corrected) {
                    if ($paramDef -is [hashtable]) {
                        $paramDef['defaultValue'] = $corrected
                    } else {
                        $paramDef.defaultValue = $corrected
                    }
                    $fixCount++
                }
            }

            # Fix allowedValues
            $allowed = $null
            if ($paramDef -is [hashtable] -and $paramDef.ContainsKey('allowedValues')) {
                $allowed = $paramDef['allowedValues']
            } elseif ($paramDef.PSObject.Properties['allowedValues']) {
                $allowed = $paramDef.allowedValues
            }

            if ($allowed -is [array]) {
                for ($i = 0; $i -lt $allowed.Count; $i++) {
                    if ($allowed[$i] -is [string] -and $effectNormalizer.ContainsKey($allowed[$i].ToLower())) {
                        $corrected = $effectNormalizer[$allowed[$i].ToLower()]
                        if ($allowed[$i] -cne $corrected) {
                            $allowed[$i] = $corrected
                            $fixCount++
                        }
                    }
                }
            }
        }
    }

    # Fix parameters inside individual policy definitions
    if ($InitiativeObject.policyDefinitions) {
        foreach ($pd in $InitiativeObject.policyDefinitions) {
            $pdParams = $pd.parameters
            if (-not $pdParams) { continue }

            $pdParamNames = if ($pdParams -is [hashtable]) {
                $pdParams.Keys
            } else {
                ($pdParams | Get-Member -MemberType Properties -ErrorAction SilentlyContinue).Name
            }

            foreach ($ppName in $pdParamNames) {
                $ppDef = if ($pdParams -is [hashtable]) { $pdParams[$ppName] } else { $pdParams.$ppName }
                if (-not $ppDef) { continue }

                # Fix 'value' property (static values, not ARM expression references)
                $ppVal = $null
                if ($ppDef -is [hashtable] -and $ppDef.ContainsKey('value')) {
                    $ppVal = $ppDef['value']
                } elseif ($ppDef.PSObject.Properties['value']) {
                    $ppVal = $ppDef.value
                }

                if ($ppVal -is [string] -and $ppVal -notmatch '^\[parameters\(' -and $effectNormalizer.ContainsKey($ppVal.ToLower())) {
                    $corrected = $effectNormalizer[$ppVal.ToLower()]
                    if ($ppVal -cne $corrected) {
                        if ($ppDef -is [hashtable]) {
                            $ppDef['value'] = $corrected
                        } else {
                            $ppDef.value = $corrected
                        }
                        $fixCount++
                    }
                }
            }
        }
    }

    return $fixCount
}

#endregion

# ============================================================================
# BEGIN MAIN SCRIPT
# ============================================================================

$ErrorActionPreference = 'Stop'

# Resolve output directory
if ([string]::IsNullOrWhiteSpace($JsonOutputPath)) {
    $JsonOutputPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

# Start transcript logging
$transcriptPath = Join-Path $JsonOutputPath "Deploy-Initiative_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
try { Start-Transcript -Path $transcriptPath -Force | Out-Null } catch {
    Write-Host "Note: Could not start transcript at $transcriptPath" -ForegroundColor Yellow
}

try {

#region Prerequisites
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host " Regulatory Compliance Custom Initiative Deployment" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

# Verify Az modules are available
$azResourcesModule = Get-Module Az.Resources -ListAvailable | Select-Object -First 1
$azPolicyModule    = Get-Module Az.PolicyInsights -ListAvailable | Select-Object -First 1

if (-not $azResourcesModule) {
    Write-Host "ERROR: Az.Resources module not found. Install with: Install-Module Az.Resources" -ForegroundColor Red
    exit 1
}
if (-not $azPolicyModule) {
    Write-Host "WARNING: Az.PolicyInsights module not found. Some features may be limited." -ForegroundColor Yellow
    Write-Host "  Install with: Install-Module Az.PolicyInsights" -ForegroundColor Yellow
}

Write-Host "  Az.Resources version: $($azResourcesModule.Version)" -ForegroundColor Gray

Import-Module Az.Resources -ErrorAction Stop
try { Import-Module Az.PolicyInsights -ErrorAction SilentlyContinue } catch {}
#endregion

#region Authentication & Context
Write-Host "`nStep 1: Authenticating to Azure..." -ForegroundColor Cyan

# Check for existing session first
$currentContext = Get-AzContext -ErrorAction SilentlyContinue
if ($currentContext) {
    Write-Host "  Active session found: $($currentContext.Account.Id)" -ForegroundColor Green
    Write-Host "  Current subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" -ForegroundColor Gray
    $reuseSession = Read-Host "  Use this session? (Y/n)"
    if ($reuseSession -eq 'n' -or $reuseSession -eq 'N') {
        $currentContext = $null
    }
}

if (-not $currentContext) {
    Write-Host "  Connecting to Azure..." -ForegroundColor Cyan
    try {
        Connect-AzAccount -ErrorAction Stop | Out-Null
        Write-Host "  Successfully connected." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Failed to connect to Azure: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Select subscription
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptions = @(Get-AzSubscription -ErrorAction Stop)
    if ($subscriptions.Count -eq 0) {
        Write-Host "ERROR: No subscriptions found for this account." -ForegroundColor Red
        exit 1
    } elseif ($subscriptions.Count -eq 1) {
        $SubscriptionId = $subscriptions[0].Id
        Write-Host "  Using subscription: $($subscriptions[0].Name) ($SubscriptionId)" -ForegroundColor Green
    } else {
        Write-Host "`n  Available subscriptions:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host "    [$i] $($subscriptions[$i].Name) - $($subscriptions[$i].Id)"
        }
        $selection = Read-ValidatedInt -Prompt "`n  Enter the number of the subscription to use" -Min 0 -Max ($subscriptions.Count - 1)
        $SubscriptionId = $subscriptions[$selection].Id
        Write-Host "  Selected: $($subscriptions[$selection].Name)" -ForegroundColor Green
    }
}

Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
Write-Host "  Context set to subscription: $SubscriptionId" -ForegroundColor Gray

# Select deployment scope (Management Group or Subscription)
if ([string]::IsNullOrWhiteSpace($ManagementGroupId)) {
    Write-Host "`n  Deploy to Management Group or Subscription?" -ForegroundColor Cyan
    Write-Host "    [1] Management Group (recommended for enterprise)"
    Write-Host "    [2] Subscription (single subscription scope)"
    $scopeChoice = Read-Host "  Enter your choice (1 or 2)"

    if ($scopeChoice -eq "1") {
        Write-Host "`n  Retrieving management groups..." -ForegroundColor Cyan
        try {
            $managementGroups = @(Get-AzManagementGroup -ErrorAction Stop)

            if ($managementGroups.Count -eq 0) {
                Write-Host "  WARNING: No management groups found. Falling back to subscription scope." -ForegroundColor Yellow
                $ManagementGroupId = $null
            } elseif ($managementGroups.Count -eq 1) {
                $ManagementGroupId = $managementGroups[0].Name
                Write-Host "  Using management group: $($managementGroups[0].DisplayName) ($ManagementGroupId)" -ForegroundColor Green
            } else {
                Write-Host "`n  Available management groups:" -ForegroundColor Cyan
                for ($i = 0; $i -lt $managementGroups.Count; $i++) {
                    Write-Host "    [$i] $($managementGroups[$i].DisplayName) - $($managementGroups[$i].Name)"
                }
                $mgSelection = Read-ValidatedInt -Prompt "`n  Enter the number of the management group" -Min 0 -Max ($managementGroups.Count - 1)
                $ManagementGroupId = $managementGroups[$mgSelection].Name
                Write-Host "  Selected: $($managementGroups[$mgSelection].DisplayName)" -ForegroundColor Green
            }
        } catch {
            Write-Host "  WARNING: Failed to retrieve management groups: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Falling back to subscription scope." -ForegroundColor Yellow
            $ManagementGroupId = $null
        }

        # Verify management group access
        if ($ManagementGroupId) {
            try {
                $mg = Get-AzManagementGroup -GroupId $ManagementGroupId -Expand -ErrorAction Stop
                Write-Host "  Verified access: $($mg.DisplayName)" -ForegroundColor Green
            } catch {
                Write-Host "  ERROR: Cannot access management group '$ManagementGroupId': $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        }
    } else {
        $ManagementGroupId = $null
        Write-Host "  Deploying to subscription scope." -ForegroundColor Green
    }
} else {
    # ManagementGroupId was provided via parameter - verify it
    try {
        $mg = Get-AzManagementGroup -GroupId $ManagementGroupId -Expand -ErrorAction Stop
        Write-Host "  Target management group: $($mg.DisplayName) ($ManagementGroupId)" -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: Cannot access management group '$ManagementGroupId': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Compute the scope string for later use
if ($ManagementGroupId) {
    $deploymentScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
    Write-Host "`n  Scope: Management Group - $ManagementGroupId" -ForegroundColor Green
} else {
    $deploymentScope = "/subscriptions/$SubscriptionId"
    Write-Host "`n  Scope: Subscription - $SubscriptionId" -ForegroundColor Green
}
#endregion

#region Step 2: Export Built-in Initiative
Write-Host "`nStep 2: Selecting compliance initiative to export..." -ForegroundColor Cyan

$builtinExportPath = Join-Path $JsonOutputPath "builtin_export.json"
$customJsonPath    = Join-Path $JsonOutputPath "custom_initiative.json"

# Allow reuse of a pre-existing custom JSON
if ($SkipExport -and (Test-Path $customJsonPath)) {
    Write-Host "  SkipExport flag set. Using existing file: $customJsonPath" -ForegroundColor Green
    $customInitiativeJson = Get-Content $customJsonPath -Raw | ConvertFrom-Json
} else {
    # Retrieve all built-in policy set definitions
    Write-Host "  Retrieving built-in policy initiatives (this may take a moment)..." -ForegroundColor Gray
    $allPolicySets = @(Get-AzPolicySetDefinition -BuiltIn -ErrorAction Stop)
    Write-Host "  Retrieved $($allPolicySets.Count) built-in policy set definitions." -ForegroundColor Gray

    # Filter by user search term
    if ([string]::IsNullOrWhiteSpace($SearchFilter)) {
        Write-Host "`n  Enter a search term to filter compliance initiatives." -ForegroundColor Cyan
        Write-Host "  Examples: NIST, CIS, HIPAA, PCI, FedRAMP, SOC, ISO, CMMC" -ForegroundColor Gray
        Write-Host "  Or press Enter to list ALL built-in initiatives." -ForegroundColor Gray
        $SearchFilter = Read-Host "  Search"
    }

    if ([string]::IsNullOrWhiteSpace($SearchFilter)) {
        $matchingInitiatives = $allPolicySets
    } else {
        $matchingInitiatives = @($allPolicySets | Where-Object {
            $dn = if ($_.DisplayName) { $_.DisplayName } elseif ($_.Properties.DisplayName) { $_.Properties.DisplayName } else { "" }
            $desc = if ($_.Description) { $_.Description } elseif ($_.Properties.Description) { $_.Properties.Description } else { "" }
            ($dn -match "(?i)$SearchFilter") -or ($desc -match "(?i)$SearchFilter")
        })
    }

    if ($matchingInitiatives.Count -eq 0) {
        Write-Host "  No initiatives matched '$SearchFilter'." -ForegroundColor Red
        Write-Host "  Try a broader search term (e.g. 'NIST' or 'CIS')." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "`n  Found $($matchingInitiatives.Count) matching initiative(s):" -ForegroundColor Green
    for ($i = 0; $i -lt $matchingInitiatives.Count; $i++) {
        $dn = if ($matchingInitiatives[$i].DisplayName) { $matchingInitiatives[$i].DisplayName } else { $matchingInitiatives[$i].Properties.DisplayName }
        $policyCount = 0
        if ($matchingInitiatives[$i].PolicyDefinition) {
            $policyCount = @($matchingInitiatives[$i].PolicyDefinition).Count
        } elseif ($matchingInitiatives[$i].Properties.PolicyDefinitions) {
            $policyCount = @($matchingInitiatives[$i].Properties.PolicyDefinitions).Count
        }
        Write-Host "    [$i] $dn ($policyCount policies)" -ForegroundColor Cyan
    }

    $initSelection = Read-ValidatedInt -Prompt "`n  Select an initiative to export (0-$($matchingInitiatives.Count - 1))" -Min 0 -Max ($matchingInitiatives.Count - 1)
    $builtInInitiative = $matchingInitiatives[$initSelection]
    $selectedDisplayName = if ($builtInInitiative.DisplayName) { $builtInInitiative.DisplayName } else { $builtInInitiative.Properties.DisplayName }

    Write-Host "`n  Selected: $selectedDisplayName" -ForegroundColor Green
    Write-Host "  Exporting built-in initiative..." -ForegroundColor Cyan

    # Save pristine PowerShell-format export
    $builtInInitiative | ConvertTo-Json -Depth 100 | Out-File $builtinExportPath -Encoding UTF8
    Write-Host "  PowerShell export saved: $builtinExportPath" -ForegroundColor Gray

    # Attempt to get the FULL definition via ARM REST API.
    # The PowerShell cmdlet export loses parameter definitions (exports as empty {}).
    # The REST API returns the complete representation with all parameters,
    # allowedValues, defaultValues, and parameter bindings.
    $builtInName = $builtInInitiative.Name
    $restSource = $null
    try {
        Write-Host "  Fetching complete definition via REST API..." -ForegroundColor Cyan
        $restResponse = Invoke-AzRestMethod -Path "/providers/Microsoft.Authorization/policySetDefinitions/${builtInName}?api-version=2023-04-01" -Method GET -ErrorAction Stop
        if ($restResponse.StatusCode -eq 200) {
            $restSource = $restResponse.Content | ConvertFrom-Json
            # Save the full REST API export as the pristine backup
            $restResponse.Content | Out-File $builtinExportPath -Encoding UTF8 -Force
            Write-Host "  Full REST API export saved (includes all parameters)." -ForegroundColor Green
        } else {
            Write-Host "  REST API returned status $($restResponse.StatusCode). Falling back to PowerShell export." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Note: REST API fetch unavailable ($($_.Exception.Message))." -ForegroundColor Yellow
        Write-Host "  Falling back to PowerShell cmdlet export (parameters may be incomplete)." -ForegroundColor Yellow
    }

    # Transform built-in -> custom format
    Write-Host "  Transforming to custom initiative format..." -ForegroundColor Cyan
    $transformSource = if ($restSource) { $restSource } else { $builtInInitiative }
    $customInitiativeJson = Convert-BuiltInToCustomJson -SourceObject $transformSource

    # Verify transformation (access through properties wrapper)
    $propsRef = $customInitiativeJson.properties
    $defCount  = @($propsRef.policyDefinitions).Count
    $grpCount  = @($propsRef.policyDefinitionGroups).Count
    Write-Host "  Transformed: $defCount policy definitions, $grpCount groups" -ForegroundColor Green
    Write-Host "  policyType set to: $($propsRef.policyType)" -ForegroundColor Green

    # Check for parameters
    $paramCount = 0
    if ($propsRef.parameters) {
        if ($propsRef.parameters -is [hashtable]) {
            $paramCount = $propsRef.parameters.Count
        } else {
            $paramCount = ($propsRef.parameters | Get-Member -MemberType Properties -ErrorAction SilentlyContinue | Measure-Object).Count
        }
    }
    if ($paramCount -eq 0) {
        Write-Host "  Note: Initiative has no top-level parameters." -ForegroundColor Yellow
        Write-Host "  Individual policy effects will use their default values." -ForegroundColor Yellow
        Write-Host "  You can add parameters by editing the custom JSON before creating the initiative." -ForegroundColor Gray
    } else {
        Write-Host "  Parameters: $paramCount" -ForegroundColor Green
    }

    # Normalize effect parameter casing (audit -> Audit, deny -> Deny, etc.)
    # Built-in initiatives may have lowercase defaults that are rejected for Custom types.
    Write-Host "  Normalizing effect parameter casing..." -ForegroundColor Cyan
    $effectFixCount = Repair-EffectParameterCasing -InitiativeObject $propsRef
    if ($effectFixCount -gt 0) {
        Write-Host "  Fixed $effectFixCount effect parameter value(s) (e.g. 'audit' -> 'Audit')." -ForegroundColor Green
    } else {
        Write-Host "  No effect casing fixes needed." -ForegroundColor Gray
    }

    # Save custom JSON
    $customInitiativeJson | ConvertTo-Json -Depth 100 | Out-File $customJsonPath -Encoding UTF8
    Write-Host "  Custom initiative JSON saved: $customJsonPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "  TIP: You can edit '$customJsonPath' to customize policies," -ForegroundColor Gray
    Write-Host "  then re-run with -SkipExport to use your modified version." -ForegroundColor Gray
}
#endregion

#region Step 3: Create or Update Custom Initiative Definition
Write-Host "`nStep 3: Creating custom initiative definition in Azure..." -ForegroundColor Cyan

# Read the custom JSON (either freshly transformed or pre-existing)
$initiativeData = if ($customInitiativeJson) {
    $customInitiativeJson
} else {
    Get-Content $customJsonPath -Raw | ConvertFrom-Json
}

# Unwrap properties container (ARM format) if present
$props = if ($initiativeData.properties) { $initiativeData.properties } else { $initiativeData }

$srcDisplayName = $props.displayName
$srcDescription = $props.description

# Determine initiative name
if ([string]::IsNullOrWhiteSpace($InitiativeName)) {
    # Generate default name from display name
    $defaultName = ($srcDisplayName -replace '[^a-zA-Z0-9_-]', '-' -replace '-{2,}', '-').Trim('-')
    if ($defaultName.Length -gt 55) { $defaultName = $defaultName.Substring(0, 55) }
    $defaultName = "$defaultName-Custom"

    Write-Host "`n  Initiative Name:" -ForegroundColor Cyan
    Write-Host "  Default: $defaultName" -ForegroundColor Gray
    Write-Host "  Requirements: alphanumeric, hyphens, underscores, max 64 chars" -ForegroundColor Gray
    $customName = Read-Host "  Press Enter for default, or type a custom name"

    if ([string]::IsNullOrWhiteSpace($customName)) {
        $InitiativeName = $defaultName
    } elseif ($customName -match '^[a-zA-Z0-9_-]{1,64}$') {
        $InitiativeName = $customName
    } else {
        Write-Host "  WARNING: Invalid name. Using default." -ForegroundColor Yellow
        $InitiativeName = $defaultName
    }
}
Write-Host "  Initiative name: $InitiativeName" -ForegroundColor Green

# Prepare policy definitions JSON (ensure array)
$policyDefs = @($props.policyDefinitions)
$policyDefsJson = ConvertTo-Json -InputObject $policyDefs -Depth 100

# Prepare metadata
$metadataJson = if ($props.metadata) {
    $props.metadata | ConvertTo-Json -Depth 10
} else { "{}" }

# Prepare parameters
$parametersJson = $null
if ($props.parameters) {
    $paramMembers = $props.parameters | Get-Member -MemberType Properties -ErrorAction SilentlyContinue
    if ($props.parameters -is [hashtable] -and $props.parameters.Count -gt 0) {
        $parametersJson = $props.parameters | ConvertTo-Json -Depth 100
    } elseif ($paramMembers -and $paramMembers.Count -gt 0) {
        $parametersJson = $props.parameters | ConvertTo-Json -Depth 100
    }
}

# Prepare group definitions
$groupDefsJson = $null
$groups = @($props.policyDefinitionGroups)
if ($groups.Count -gt 0) {
    Write-Host "  Policy definition groups: $($groups.Count)" -ForegroundColor Gray
    $groupDefsJson = ConvertTo-Json -InputObject $groups -Depth 100
}

# Check if initiative already exists (idempotency)
$existingInitiative = $null
try {
    if ($ManagementGroupId) {
        $existingInitiative = Get-AzPolicySetDefinition -Name $InitiativeName -ManagementGroupName $ManagementGroupId -ErrorAction SilentlyContinue
    } else {
        $existingInitiative = Get-AzPolicySetDefinition -Name $InitiativeName -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    }
} catch {
    # Not found - that's fine
}

if ($existingInitiative) {
    Write-Host ""
    Write-Host "  Initiative '$InitiativeName' already exists at this scope." -ForegroundColor Yellow
    Write-Host "    [U] Update the existing initiative" -ForegroundColor Cyan
    Write-Host "    [S] Skip creation (keep existing, proceed to assignment)" -ForegroundColor Cyan
    Write-Host "    [A] Abort" -ForegroundColor Cyan
    $idempotencyChoice = Read-Host "  Choose (U/S/A)"

    switch ($idempotencyChoice.ToUpper()) {
        'U' {
            Write-Host "  Updating existing initiative..." -ForegroundColor Cyan

            $updateParams = @{
                Name             = $InitiativeName
                DisplayName      = "$srcDisplayName (Custom)"
                Description      = $srcDescription
                PolicyDefinition = $policyDefsJson
                Metadata         = $metadataJson
            }
            if ($parametersJson) { $updateParams.Parameter = $parametersJson }
            if ($groupDefsJson)  { $updateParams.GroupDefinition = $groupDefsJson }

            if ($ManagementGroupId) {
                $updateParams.ManagementGroupName = $ManagementGroupId
            } else {
                $updateParams.SubscriptionId = $SubscriptionId
            }

            if ($PSCmdlet.ShouldProcess($InitiativeName, "Update policy set definition")) {
                $newInitiative = Set-AzPolicySetDefinition @updateParams -ErrorAction Stop
                if (-not $newInitiative -or [string]::IsNullOrWhiteSpace($newInitiative.Name)) {
                    throw "Set-AzPolicySetDefinition returned no result."
                }
                Write-Host "  Initiative updated successfully." -ForegroundColor Green
                Write-Host "  Resource ID: $($newInitiative.ResourceId)" -ForegroundColor Gray
            }
        }
        'S' {
            Write-Host "  Skipping creation. Using existing initiative." -ForegroundColor Green
            $newInitiative = $existingInitiative
        }
        default {
            Write-Host "  Aborted by user." -ForegroundColor Yellow
            exit 0
        }
    }
} else {
    # Create new initiative
    $createParams = @{
        Name             = $InitiativeName
        DisplayName      = "$srcDisplayName (Custom)"
        Description       = $srcDescription
        PolicyDefinition = $policyDefsJson
        Metadata         = $metadataJson
    }
    if ($parametersJson) { $createParams.Parameter = $parametersJson }
    if ($groupDefsJson)  { $createParams.GroupDefinition = $groupDefsJson }

    if ($ManagementGroupId) {
        $createParams.ManagementGroupName = $ManagementGroupId
        Write-Host "  Creating at Management Group: $ManagementGroupId" -ForegroundColor Cyan
    } else {
        $createParams.SubscriptionId = $SubscriptionId
        Write-Host "  Creating at Subscription: $SubscriptionId" -ForegroundColor Cyan
    }

    if ($PSCmdlet.ShouldProcess($InitiativeName, "Create policy set definition")) {
        try {
            $newInitiative = New-AzPolicySetDefinition @createParams -ErrorAction Stop

            # Validate the result (some errors are non-terminating)
            if (-not $newInitiative -or [string]::IsNullOrWhiteSpace($newInitiative.Name)) {
                throw "New-AzPolicySetDefinition returned no result. The initiative may not have been created."
            }

            Write-Host "  Custom initiative created successfully!" -ForegroundColor Green
            Write-Host "  Resource ID: $($newInitiative.ResourceId)" -ForegroundColor Gray
            Write-Host "  Name: $($newInitiative.Name)" -ForegroundColor Gray
        } catch {
            $errMsg = $_.Exception.Message
            Write-Host "  ERROR: Failed to create initiative." -ForegroundColor Red
            Write-Host "  $errMsg" -ForegroundColor Red
            Write-Host ""

            # Provide targeted guidance based on the error
            if ($errMsg -match 'default value.*not valid|allowed values') {
                Write-Host "  DIAGNOSIS: A policy parameter has an invalid default value (often a casing issue)." -ForegroundColor Yellow
                Write-Host "  The built-in initiative may use 'audit' but the policy definition now requires 'Audit'." -ForegroundColor White
                Write-Host "" 
                Write-Host "  FIX: Edit '$customJsonPath':" -ForegroundColor Yellow
                Write-Host "  1. Find the 'parameters' section and look for effect-related defaults" -ForegroundColor White
                Write-Host "  2. Change lowercase values to PascalCase: audit->Audit, deny->Deny, disabled->Disabled" -ForegroundColor White
                Write-Host "  3. Re-run: .\Deploy-CustomNIST-Initiative.ps1 -SkipExport" -ForegroundColor Cyan
            } else {
                Write-Host "  TROUBLESHOOTING:" -ForegroundColor Yellow
                Write-Host "  - Ensure you have Policy Contributor or Owner role at the target scope" -ForegroundColor White
                Write-Host "  - If the error mentions parameter issues, edit '$customJsonPath'" -ForegroundColor White
                Write-Host "    to fix parameters, then re-run with -SkipExport" -ForegroundColor White
                Write-Host "  - For very large initiatives, check if you're hitting size limits" -ForegroundColor White
            }
            exit 1
        }
    }
}
#endregion

#region Step 4: Optional Assignment
if (-not $SkipAssignment) {
    Write-Host "`nStep 4: Assign initiative to scope" -ForegroundColor Cyan
    Write-Host "  Would you like to assign the initiative now?" -ForegroundColor White
    $assignChoice = Read-Host "  Assign initiative? (Y/n)"

    if ($assignChoice -ne 'n' -and $assignChoice -ne 'N') {
        # Generate default assignment name (max 24 chars)
        $defaultAssignName = ($InitiativeName -replace '[^a-zA-Z0-9-]', '').Substring(0, [Math]::Min($InitiativeName.Length, 24))
        Write-Host "`n  Assignment name (max 24 chars)." -ForegroundColor Gray
        Write-Host "  Default: $defaultAssignName" -ForegroundColor Gray
        $assignNameInput = Read-Host "  Press Enter for default, or type a name"

        if ([string]::IsNullOrWhiteSpace($assignNameInput)) {
            $assignmentName = $defaultAssignName
        } else {
            $assignmentName = $assignNameInput.Substring(0, [Math]::Min($assignNameInput.Length, 24))
        }

        # Get the policy set definition object
        $initiativeForAssignment = if ($newInitiative) { $newInitiative } else {
            if ($ManagementGroupId) {
                Get-AzPolicySetDefinition -Name $InitiativeName -ManagementGroupName $ManagementGroupId
            } else {
                Get-AzPolicySetDefinition -Name $InitiativeName -SubscriptionId $SubscriptionId
            }
        }

        # Prompt for location (needed for managed identity)
        Write-Host "  Enter Azure region for managed identity (e.g. eastus, westus2, centralus)." -ForegroundColor Gray
        $location = Read-Host "  Location (default: eastus)"
        if ([string]::IsNullOrWhiteSpace($location)) { $location = "eastus" }

        $assignParams = @{
            Name                = $assignmentName
            DisplayName         = "$srcDisplayName (Custom)"
            Scope               = $deploymentScope
            PolicySetDefinition = $initiativeForAssignment
            Location            = $location
            IdentityType        = 'SystemAssigned'
        }

        Write-Host "`n  Creating assignment '$assignmentName' at scope: $deploymentScope" -ForegroundColor Cyan
        if ($PSCmdlet.ShouldProcess($assignmentName, "Create policy assignment")) {
            try {
                $assignment = New-AzPolicyAssignment @assignParams
                Write-Host "  Assignment created successfully!" -ForegroundColor Green
                Write-Host "  Assignment ID: $($assignment.ResourceId)" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  IMPORTANT POST-ASSIGNMENT STEPS:" -ForegroundColor Yellow
                Write-Host "  1. Grant the managed identity Contributor (or appropriate) role:" -ForegroundColor White
                Write-Host "     Principal ID: $($assignment.Identity.PrincipalId)" -ForegroundColor Cyan
                Write-Host "  2. Compliance evaluation begins in 10-30 minutes" -ForegroundColor White
                Write-Host "  3. Run 'Start-AzPolicyComplianceScan -AsJob' to trigger immediate scan" -ForegroundColor White
            } catch {
                Write-Host "  ERROR: Failed to create assignment: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "  You can assign manually - see instructions below." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  Skipping assignment." -ForegroundColor Gray
    }
} else {
    Write-Host "`nStep 4: Assignment skipped (SkipAssignment flag set)." -ForegroundColor Gray
}
#endregion

#region Step 5: Summary and Next Steps
Write-Host "`n============================================================================" -ForegroundColor Cyan
Write-Host " DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan

Write-Host "`n  Initiative: $InitiativeName" -ForegroundColor White
Write-Host "  Display Name: $srcDisplayName (Custom)" -ForegroundColor White
Write-Host "  Scope: $deploymentScope" -ForegroundColor White
Write-Host "  Custom JSON: $customJsonPath" -ForegroundColor White
Write-Host "  Built-in Export: $builtinExportPath" -ForegroundColor White

if (-not $SkipAssignment -and ($assignChoice -ne 'n' -and $assignChoice -ne 'N')) {
    Write-Host "  Assignment: $assignmentName" -ForegroundColor White
}

Write-Host "`n  Manual Assignment (if not done above):" -ForegroundColor Yellow
Write-Host "  -----------------------------------------------" -ForegroundColor Gray
Write-Host "  Portal: Azure Portal > Policy > Definitions > Type: Custom" -ForegroundColor Gray
Write-Host "          Find '$InitiativeName' > Assign" -ForegroundColor Gray
Write-Host ""
Write-Host "  PowerShell:" -ForegroundColor Gray
if ($ManagementGroupId) {
    Write-Host "    `$init = Get-AzPolicySetDefinition -Name '$InitiativeName' -ManagementGroupName '$ManagementGroupId'" -ForegroundColor Cyan
    Write-Host "    New-AzPolicyAssignment ``" -ForegroundColor Cyan
    Write-Host "      -Name '<AssignmentName>' ``" -ForegroundColor Cyan
    Write-Host "      -Scope '/providers/Microsoft.Management/managementGroups/$ManagementGroupId' ``" -ForegroundColor Cyan
} else {
    Write-Host "    `$init = Get-AzPolicySetDefinition -Name '$InitiativeName' -SubscriptionId '$SubscriptionId'" -ForegroundColor Cyan
    Write-Host "    New-AzPolicyAssignment ``" -ForegroundColor Cyan
    Write-Host "      -Name '<AssignmentName>' ``" -ForegroundColor Cyan
    Write-Host "      -Scope '/subscriptions/$SubscriptionId' ``" -ForegroundColor Cyan
}
Write-Host "      -PolicySetDefinition `$init ``" -ForegroundColor Cyan
Write-Host "      -Location 'eastus' ``" -ForegroundColor Cyan
Write-Host "      -IdentityType 'SystemAssigned'" -ForegroundColor Cyan

Write-Host "`n  Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Grant RBAC roles to the managed identity (if assigned)" -ForegroundColor White
Write-Host "  2. Wait 10-30 minutes for initial compliance evaluation" -ForegroundColor White
Write-Host "  3. Monitor: Azure Portal > Policy > Compliance" -ForegroundColor White
Write-Host "  4. Create exemptions as needed (see Manage-PolicyExemptions.ps1)" -ForegroundColor White
Write-Host "  5. Run remediation tasks for deployIfNotExists/modify policies" -ForegroundColor White

Write-Host "`n  Compliance Monitoring:" -ForegroundColor Gray
if ($ManagementGroupId) {
    Write-Host "    Get-AzPolicyStateSummary -ManagementGroupName '$ManagementGroupId'" -ForegroundColor Cyan
} else {
    Write-Host "    Get-AzPolicyStateSummary -SubscriptionId '$SubscriptionId'" -ForegroundColor Cyan
}
Write-Host "    Start-AzPolicyComplianceScan -AsJob   # trigger on-demand scan" -ForegroundColor Cyan

Write-Host "`n  For detailed instructions, see README.md" -ForegroundColor Gray
Write-Host "============================================================================" -ForegroundColor Cyan
#endregion

} finally {
    # Always stop transcript
    try { Stop-Transcript | Out-Null } catch {}
}

#region ============================================================================
# UTILITY COMMANDS FOR MANAGING CUSTOM INITIATIVE
# ============================================================================

<#
.SYNOPSIS
    Utility commands for managing your custom compliance initiative.

.DESCRIPTION
    This section contains useful commands for:
    - Updating the custom initiative
    - Managing assignments
    - Creating and managing exemptions
    - Monitoring compliance
    - Running remediations

.NOTES
    Uncomment and run commands as needed.
    Replace <InitiativeName>, <AssignmentName>, <SubscriptionId>, <ManagementGroupId>
    with your actual values.
#>

# ----------------------------------------------------------------------------
# UPDATE CUSTOM INITIATIVE
# ----------------------------------------------------------------------------
<#
# After editing custom_initiative.json, update the initiative:
$jsonContent = Get-Content (Join-Path $PSScriptRoot "custom_initiative.json") -Raw | ConvertFrom-Json
$props = if ($jsonContent.properties) { $jsonContent.properties } else { $jsonContent }
$policyDefinitions = ConvertTo-Json -InputObject @($props.policyDefinitions) -Depth 100

$params = @{
    Name             = "<InitiativeName>"
    PolicyDefinition = $policyDefinitions
}

# Set scope
# $params.ManagementGroupName = "<ManagementGroupId>"
$params.SubscriptionId = "<SubscriptionId>"

# Add other properties if changed
if ($props.displayName)            { $params.DisplayName    = $props.displayName }
if ($props.description)            { $params.Description    = $props.description }
if ($props.metadata)               { $params.Metadata       = $props.metadata | ConvertTo-Json -Depth 10 }
if ($props.policyDefinitionGroups) { $params.GroupDefinition = ConvertTo-Json -InputObject @($props.policyDefinitionGroups) -Depth 100 }

Set-AzPolicySetDefinition @params
#>

# ----------------------------------------------------------------------------
# MANAGE ASSIGNMENTS
# ----------------------------------------------------------------------------
<#
# Set scope
$scope = "/subscriptions/<SubscriptionId>"
# $scope = "/providers/Microsoft.Management/managementGroups/<ManagementGroupId>"

# List all policy assignments in scope
Get-AzPolicyAssignment -Scope $scope

# Get specific assignment
Get-AzPolicyAssignment -Name "<AssignmentName>" -Scope $scope

# Remove an assignment
Remove-AzPolicyAssignment -Name "<AssignmentName>" -Scope $scope -Confirm:$false
#>

# ----------------------------------------------------------------------------
# CREATE POLICY EXEMPTIONS
# ----------------------------------------------------------------------------
<#
# Example 1: Exempt a resource group from all policies in the initiative
$exemption1 = New-AzPolicyExemption `
    -Name "Dev-Environment-Full-Exemption" `
    -DisplayName "Development Environment Full Exemption" `
    -Description "Temporary exemption for dev environment during testing phase" `
    -Scope "/subscriptions/<SubscriptionId>/resourceGroups/rg-dev" `
    -PolicyAssignment (Get-AzPolicyAssignment -Name "<AssignmentName>") `
    -ExemptionCategory "Waiver" `
    -ExpiresOn (Get-Date).AddMonths(3)

# Example 2: Exempt specific policies within the initiative
$exemption2 = New-AzPolicyExemption `
    -Name "SQL-Audit-Exemption-VM001" `
    -DisplayName "SQL Audit Exemption for VM001" `
    -Description "VM001 has compensating controls" `
    -Scope "/subscriptions/<SubscriptionId>/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm001" `
    -PolicyAssignment (Get-AzPolicyAssignment -Name "<AssignmentName>") `
    -PolicyDefinitionReferenceId @("EnableAuditingOnSQLServers", "SQLServerAuditingSettings") `
    -ExemptionCategory "Mitigated" `
    -ExpiresOn (Get-Date).AddYears(1) `
    -Metadata (@{
        "CompensatingControl" = "Azure Security Center monitoring enabled"
        "ApprovalTicket"      = "SNOW-12345"
    } | ConvertTo-Json)

# Example 3: Exempt based on resource tags
$devResources = Get-AzResource -TagName "Environment" -TagValue "Development"
foreach ($resource in $devResources) {
    New-AzPolicyExemption `
        -Name "dev-exemption-$($resource.Name)" `
        -DisplayName "Development Exemption - $($resource.Name)" `
        -Scope $resource.ResourceId `
        -PolicyAssignment (Get-AzPolicyAssignment -Name "<AssignmentName>") `
        -ExemptionCategory "Waiver" `
        -ExpiresOn (Get-Date).AddMonths(6)
}
#>

# ----------------------------------------------------------------------------
# MANAGE EXEMPTIONS
# ----------------------------------------------------------------------------
<#
$scope = "/subscriptions/<SubscriptionId>"

# List all exemptions
Get-AzPolicyExemption -Scope $scope

# Update exemption expiration
$exemption = Get-AzPolicyExemption -Name "Dev-Environment-Full-Exemption"
Set-AzPolicyExemption -Id $exemption.ResourceId -ExpiresOn (Get-Date).AddMonths(6)

# Remove an exemption
Remove-AzPolicyExemption -Name "Dev-Environment-Full-Exemption" -Scope "$scope/resourceGroups/rg-dev"

# Find exemptions expiring within 30 days
$allExemptions = Get-AzPolicyExemption -Scope $scope
$expiring = $allExemptions | Where-Object {
    $_.Properties.ExpiresOn -and $_.Properties.ExpiresOn -lt (Get-Date).AddDays(30)
}
$expiring | Select-Object Name,
    @{Name="ExpiresOn"; Expression={$_.Properties.ExpiresOn}},
    @{Name="Assignment"; Expression={$_.Properties.PolicyAssignmentId}} |
    Format-Table
#>

# ----------------------------------------------------------------------------
# COMPLIANCE MONITORING
# ----------------------------------------------------------------------------
<#
# Trigger on-demand compliance scan
Start-AzPolicyComplianceScan -AsJob

# Compliance summary
# Get-AzPolicyStateSummary -ManagementGroupName "<ManagementGroupId>"
Get-AzPolicyStateSummary -SubscriptionId "<SubscriptionId>"

# Detailed compliance for specific assignment
$details = Get-AzPolicyState -PolicyAssignmentName "<AssignmentName>"
$details | Select-Object ResourceId, ComplianceState, PolicyDefinitionName, PolicyDefinitionReferenceId |
    Export-Csv "compliance_report.csv" -NoTypeInformation

# Group by compliance state
$details | Group-Object ComplianceState | Select-Object Name, Count | Format-Table

# Non-compliant resources
$details | Where-Object { $_.ComplianceState -eq "NonCompliant" } |
    Select-Object ResourceId, PolicyDefinitionName | Format-Table
#>

# ----------------------------------------------------------------------------
# REMEDIATION
# ----------------------------------------------------------------------------
<#
$assignment = Get-AzPolicyAssignment -Name "<AssignmentName>"
$scope = "/subscriptions/<SubscriptionId>"

# Remediate all non-compliant resources
Start-AzPolicyRemediation `
    -Name "remediate-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
    -PolicyAssignmentId $assignment.ResourceId `
    -Scope $scope

# Remediate specific policy within the initiative
Start-AzPolicyRemediation `
    -Name "remediate-sql-audit-$(Get-Date -Format 'yyyyMMdd')" `
    -PolicyAssignmentId $assignment.ResourceId `
    -PolicyDefinitionReferenceId "EnableAuditingOnSQLServers" `
    -Scope $scope

# Monitor remediation progress
Get-AzPolicyRemediation -Scope $scope |
    Where-Object { $_.Properties.ProvisioningState -eq "Running" }
#>

# ----------------------------------------------------------------------------
# EXPORT COMPLIANCE REPORT
# ----------------------------------------------------------------------------
<#
$assignment = Get-AzPolicyAssignment -Name "<AssignmentName>"
$compliance = Get-AzPolicyState -PolicyAssignmentId $assignment.ResourceId

$report = $compliance | Select-Object `
    @{Name="SubscriptionId";  Expression={$_.SubscriptionId}},
    @{Name="ResourceGroup";   Expression={$_.ResourceGroup}},
    @{Name="ResourceType";    Expression={$_.ResourceType}},
    @{Name="ResourceName";    Expression={$_.ResourceId.Split('/')[-1]}},
    @{Name="ComplianceState"; Expression={$_.ComplianceState}},
    @{Name="PolicyName";      Expression={$_.PolicyDefinitionName}},
    @{Name="ReferenceId";     Expression={$_.PolicyDefinitionReferenceId}},
    @{Name="Timestamp";       Expression={$_.Timestamp}}

$report | Export-Csv "Compliance_Report_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation

# Summary by resource group
$compliance | Group-Object ResourceGroup | Select-Object `
    Name,
    @{Name="Total";        Expression={$_.Count}},
    @{Name="Compliant";    Expression={($_.Group | Where-Object {$_.ComplianceState -eq "Compliant"}).Count}},
    @{Name="NonCompliant"; Expression={($_.Group | Where-Object {$_.ComplianceState -eq "NonCompliant"}).Count}} |
    Export-Csv "Compliance_Summary_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
#>

# ----------------------------------------------------------------------------
# FINDING POLICY DEFINITION REFERENCE IDs
# ----------------------------------------------------------------------------
<#
# Read from the custom initiative JSON (ARM format with properties wrapper)
$json = Get-Content (Join-Path $PSScriptRoot "custom_initiative.json") -Raw | ConvertFrom-Json
$jsonProps = if ($json.properties) { $json.properties } else { $json }
$jsonProps.policyDefinitions |
    Select-Object policyDefinitionReferenceId, policyDefinitionId |
    Format-Table

# Export to CSV
$jsonProps.policyDefinitions |
    Select-Object policyDefinitionReferenceId, policyDefinitionId |
    Export-Csv "policy_reference_ids.csv" -NoTypeInformation

# Search for specific policy
$jsonProps.policyDefinitions |
    Where-Object { $_.policyDefinitionId -like "*SQL*" } |
    Select-Object policyDefinitionReferenceId, policyDefinitionId
#>

#endregion

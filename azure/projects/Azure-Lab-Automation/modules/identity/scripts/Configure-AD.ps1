<#
.SYNOPSIS
    Configure Active Directory -- OUs, Security Groups, Service Accounts, gMSA
    Runs as a VM RunCommand on the first domain controller after forest promotion.

.PARAMETER DomainName
    Fully qualified domain name (e.g., azlab.local)

.PARAMETER SvcPassword
    Password for service accounts (passed as protectedParameter)

.PARAMETER EntraIdDomain
    Entra ID tenant domain (e.g., usaavd.com). When specified with
    DomainStrategy='independent', this is added as a UPN suffix to the AD forest.

.PARAMETER DomainStrategy
    'subdomain' = AD domain is a subdomain of EntraIdDomain (UPNs already match)
    'independent' = AD domain is separate; EntraIdDomain added as UPN suffix
#>
param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$SvcPassword,

    [Parameter()]
    [string]$EntraIdDomain = '',

    [Parameter()]
    [string]$DomainStrategy = 'subdomain'
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path "C:\WindowsTemp\ConfigureAD.log" -Append

# ============================================================================
# Wait for AD DS to be fully operational after DC promotion reboot
# ============================================================================
Write-Output "Waiting for Active Directory to become available..."
$maxWait = 600
$waited = 0
while ($waited -lt $maxWait) {
    try {
        Get-ADDomain -ErrorAction Stop | Out-Null
        Write-Output "  AD DS is ready (waited ${waited}s)"
        break
    } catch {
        Start-Sleep -Seconds 15
        $waited += 15
    }
}
if ($waited -ge $maxWait) { throw "AD DS did not become ready within $maxWait seconds" }

Import-Module ActiveDirectory

$svcSecure = ConvertTo-SecureString $SvcPassword -AsPlainText -Force
$domainDN = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','

# ============================================================================
# Configure DNS Forwarder -- Azure internal DNS (168.63.129.16)
# ============================================================================
# The DC's DNS server is authoritative for the AD zone only.  Without a
# forwarder, VMs using the DC as their DNS server cannot resolve public names
# (e.g., *.file.core.windows.net, *.blob.core.windows.net, Windows Update).
# Azure's wireserver DNS (168.63.129.16) resolves all public + Azure private
# DNS names and is reachable from every Azure VM.
# ============================================================================
Write-Output "Configuring DNS forwarder to Azure DNS (168.63.129.16) on ALL domain controllers..."
try {
    $allDCs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
    foreach ($dc in $allDCs) {
        try {
            # Use Set (not Add) to ensure 168.63.129.16 is the ONLY forwarder.
            # Add-DnsServerForwarder can leave stale entries (e.g., other DC IPs)
            # which cause forwarding loops or bypass Azure Private DNS zones.
            Set-DnsServerForwarder -ComputerName $dc -IPAddress '168.63.129.16'
            Write-Output "  DNS forwarder set on ${dc}: 168.63.129.16"
        } catch {
            Write-Output "  WARNING: Failed to configure DNS forwarder on ${dc} (non-fatal): $_"
        }
    }
} catch {
    Write-Output "  WARNING: Failed to enumerate domain controllers (non-fatal): $_"
}

# ============================================================================
# Add Entra ID UPN Suffix (independent domain strategy only)
# ============================================================================
if (-not [string]::IsNullOrWhiteSpace($EntraIdDomain) -and $DomainStrategy -eq 'independent') {
    Write-Output "Adding Entra ID UPN suffix: $EntraIdDomain..."
    try {
        $forest = Get-ADForest
        if ($forest.UPNSuffixes -notcontains $EntraIdDomain) {
            Set-ADForest -Identity $forest.Name -UPNSuffixes @{Add=$EntraIdDomain}
            Write-Output "  UPN suffix added: $EntraIdDomain"
        } else {
            Write-Output "  UPN suffix already exists: $EntraIdDomain"
        }
    } catch {
        Write-Output "  WARNING: Failed to add UPN suffix (non-fatal): $_"
    }
} elseif (-not [string]::IsNullOrWhiteSpace($EntraIdDomain)) {
    Write-Output "Skipping UPN suffix -- domain strategy is '$DomainStrategy' (subdomain UPNs match Entra ID)"
}

# ============================================================================
# Create OU Structure
# ============================================================================
Write-Output "Creating OU structure..."
$ous = @(
    @{ Name = 'Lab Accounts';       Parent = $domainDN }
    @{ Name = 'Service Accounts';   Parent = "OU=Lab Accounts,$domainDN" }
    @{ Name = 'Admins';             Parent = "OU=Lab Accounts,$domainDN" }
    @{ Name = 'Lab Groups';         Parent = $domainDN }
    @{ Name = 'Lab Servers';        Parent = $domainDN }
    @{ Name = 'SQL Servers';        Parent = "OU=Lab Servers,$domainDN" }
    @{ Name = 'App Servers';        Parent = "OU=Lab Servers,$domainDN" }
    @{ Name = 'Storage Accounts';   Parent = "OU=Lab Servers,$domainDN" }
)
foreach ($ou in $ous) {
    $ouDN = "OU=$($ou.Name),$($ou.Parent)"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Parent -ProtectedFromAccidentalDeletion $false
        Write-Output "  Created OU: $ouDN"
    } else {
        Write-Output "  OU already exists: $ouDN"
    }
}

# ============================================================================
# Create Security Groups
# ============================================================================
Write-Output "Creating security groups..."
$groupOU = "OU=Lab Groups,$domainDN"
$groups = @(
    @{ Name = 'GRP-DomainAdmins-Lab'; Description = 'Lab domain administrators (manually populated)' }
    @{ Name = 'GRP-SQLAdmins';        Description = 'SQL Server administrators' }
    @{ Name = 'GRP-AppAdmins';        Description = 'Application server administrators' }
    @{ Name = 'GRP-MCMAdmins';        Description = 'MCM server administrators' }
    @{ Name = 'GRP-ServerAdmins';     Description = 'General server local administrators' }
    @{ Name = 'GRP-DomainJoin';       Description = 'Accounts permitted to domain-join machines' }
)
foreach ($g in $groups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g.Name -GroupScope Global -GroupCategory Security `
            -Path $groupOU -Description $g.Description
        Write-Output "  Created group: $($g.Name)"
    } else {
        Write-Output "  Group already exists: $($g.Name)"
    }
}

# Add GRP-DomainAdmins-Lab to Domain Admins for elevated lab access
Add-ADGroupMember -Identity 'Domain Admins' -Members 'GRP-DomainAdmins-Lab' -ErrorAction SilentlyContinue
Write-Output "  Added GRP-DomainAdmins-Lab to Domain Admins"

# ============================================================================
# Create Service Accounts
# ============================================================================
Write-Output "Creating service accounts..."
$svcOU = "OU=Service Accounts,OU=Lab Accounts,$domainDN"
$svcAccounts = @(
    @{ Name = 'svc-domjoin';   Desc = 'Domain Join service account';    Groups = @('GRP-DomainJoin') }
    @{ Name = 'svc-appadmin'; Desc = 'Application Admin service account'; Groups = @('GRP-AppAdmins') }
    @{ Name = 'svc-sqlsvc';    Desc = 'SQL Server service account';     Groups = @('GRP-SQLAdmins') }
    @{ Name = 'svc-sqlagent';  Desc = 'SQL Agent service account';      Groups = @('GRP-SQLAdmins') }
    @{ Name = 'svc-appnaa';   Desc = 'Application Network Access Account';     Groups = @('GRP-AppAdmins') }
)

# --- Admin accounts (placed in OU=Admins,OU=Lab Accounts) --------------------
$adminOU = "OU=Admins,OU=Lab Accounts,$domainDN"
$adminAccounts = @(
    @{ Name = 'lab-admin';  Desc = 'Lab infrastructure admin (delegated OU management)'; Groups = @('GRP-ServerAdmins', 'GRP-SQLAdmins', 'GRP-AppAdmins', 'GRP-MCMAdmins') }
    @{ Name = 'mcm-admin';  Desc = 'MCM Administrator account'; Groups = @('GRP-AppAdmins', 'GRP-MCMAdmins') }
    @{ Name = 'sql-admin';  Desc = 'SQL Administrator account';  Groups = @('GRP-SQLAdmins') }
)
foreach ($svc in $svcAccounts) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($svc.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $svc.Name `
            -SamAccountName $svc.Name `
            -UserPrincipalName "$($svc.Name)@$DomainName" `
            -Path $svcOU `
            -Description $svc.Desc `
            -AccountPassword $svcSecure `
            -PasswordNeverExpires $true `
            -CannotChangePassword $true `
            -Enabled $true
        Write-Output "  Created user: $($svc.Name)"
    } else {
        Write-Output "  User already exists: $($svc.Name)"
        # Always sync password so domain-join credentials stay consistent
        Set-ADAccountPassword -Identity $svc.Name -Reset -NewPassword $svcSecure
        Write-Output "  Password synchronized for: $($svc.Name)"
    }
    # Add to groups
    foreach ($grp in $svc.Groups) {
        Add-ADGroupMember -Identity $grp -Members $svc.Name -ErrorAction SilentlyContinue
    }
}

# --- Create admin accounts in the Admins OU -----------------------------------
Write-Output "Creating admin accounts..."
foreach ($adm in $adminAccounts) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($adm.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $adm.Name `
            -SamAccountName $adm.Name `
            -UserPrincipalName "$($adm.Name)@$DomainName" `
            -Path $adminOU `
            -Description $adm.Desc `
            -AccountPassword $svcSecure `
            -PasswordNeverExpires $true `
            -CannotChangePassword $true `
            -Enabled $true
        Write-Output "  Created admin: $($adm.Name)"
    } else {
        Write-Output "  Admin already exists: $($adm.Name)"
        Set-ADAccountPassword -Identity $adm.Name -Reset -NewPassword $svcSecure
        Write-Output "  Password synchronized for: $($adm.Name)"
    }
    foreach ($grp in $adm.Groups) {
        Add-ADGroupMember -Identity $grp -Members $adm.Name -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Delegate Domain-Join Permissions to svc-domjoin
# ============================================================================
Write-Output "Delegating domain-join permissions to svc-domjoin..."
try {
    $domJoinUser = Get-ADUser -Identity 'svc-domjoin'
    $computersDN = "CN=Computers,$domainDN"
    $acl = Get-Acl "AD:\$computersDN"

    $guidComputer  = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'  # Computer object class
    $guidNull      = [guid]'00000000-0000-0000-0000-000000000000'
    $sid = New-Object System.Security.Principal.SecurityIdentifier($domJoinUser.SID)

    # Allow creating Computer objects
    $ace1 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, 'CreateChild', 'Allow', $guidComputer, 'All'
    )
    # Allow writing all properties on Computer objects
    $ace2 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, 'WriteProperty', 'Allow', $guidNull, 'Descendents', $guidComputer
    )
    $acl.AddAccessRule($ace1)
    $acl.AddAccessRule($ace2)
    Set-Acl "AD:\$computersDN" $acl
    Write-Output "  Domain-join delegation configured"
} catch {
    Write-Output "  WARNING: Domain-join delegation failed (non-fatal): $_"
}

# ============================================================================
# Delegate OU Management to lab-admin
# ============================================================================
# lab-admin gets GenericAll (full control) over the Lab OUs so it can manage
# users, groups, computers, and child OUs without being a Domain Admin.
Write-Output "Delegating OU management to lab-admin..."
try {
    $labAdminUser = Get-ADUser -Identity 'lab-admin'
    $labAdminSid = New-Object System.Security.Principal.SecurityIdentifier($labAdminUser.SID)
    $guidNull = [guid]'00000000-0000-0000-0000-000000000000'

    $delegateOUs = @(
        "OU=Lab Servers,$domainDN"
        "OU=Lab Accounts,$domainDN"
        "OU=Lab Groups,$domainDN"
    )
    foreach ($ouDN in $delegateOUs) {
        $acl = Get-Acl "AD:\$ouDN"
        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $labAdminSid, 'GenericAll', 'Allow', 'Descendents', $guidNull
        )
        $acl.AddAccessRule($ace)
        Set-Acl "AD:\$ouDN" $acl
        Write-Output "  Delegated full control on: $ouDN"
    }

    # Also grant lab-admin local admin on domain-joined servers via
    # membership in GRP-ServerAdmins (GPO or restricted groups expected
    # to map GRP-ServerAdmins to the local Administrators group).
    Write-Output "  lab-admin delegated over Lab Servers, Lab Accounts, Lab Groups"
} catch {
    Write-Output "  WARNING: lab-admin OU delegation failed (non-fatal): $_"
}

# ============================================================================
# Create Group Managed Service Account (gMSA) for SQL Server
# ============================================================================
Write-Output "Creating gMSA: gmsa-sqlsvc..."
try {
    # Create KDS Root Key -- use EffectiveTime in the past for lab (immediate effect)
    if (-not (Get-KdsRootKey -ErrorAction SilentlyContinue)) {
        Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
        Write-Output "  Created KDS Root Key (effective immediately for lab)"
        Start-Sleep -Seconds 10  # Brief wait for replication
    }

    if (-not (Get-ADServiceAccount -Filter "Name -eq 'gmsa-sqlsvc'" -ErrorAction SilentlyContinue)) {
        New-ADServiceAccount -Name 'gmsa-sqlsvc' `
            -DNSHostName "gmsa-sqlsvc.$DomainName" `
            -Description 'Group Managed Service Account for SQL Server' `
            -KerberosEncryptionType AES128, AES256 `
            -ManagedPasswordIntervalInDays 30 `
            -PrincipalsAllowedToRetrieveManagedPassword 'GRP-SQLAdmins'
        Write-Output "  Created gMSA: gmsa-sqlsvc"
    } else {
        Write-Output "  gMSA already exists: gmsa-sqlsvc"
    }
    Write-Output "  NOTE: After SQL servers join the domain, add their computer accounts:"
    Write-Output "    Set-ADServiceAccount gmsa-sqlsvc -PrincipalsAllowedToRetrieveManagedPassword @{Add='YOURPC$'}"
} catch {
    Write-Output "  WARNING: gMSA creation failed (non-fatal): $_"
}

# ============================================================================
# Summary
# ============================================================================
Write-Output ""
Write-Output "=========================================="
Write-Output " AD Configuration Complete"
Write-Output "=========================================="
Write-Output " Domain:    $DomainName"
Write-Output " Domain DN: $domainDN"
Write-Output " OUs:       Lab Accounts, Service Accounts, Admins, Lab Groups, Lab Servers, SQL Servers, App Servers"
Write-Output " Groups:    GRP-DomainAdmins-Lab (manual), GRP-SQLAdmins, GRP-AppAdmins, GRP-MCMAdmins, GRP-ServerAdmins, GRP-DomainJoin"
Write-Output " Accounts:  svc-domjoin, svc-appadmin, svc-sqlsvc, svc-sqlagent, svc-appnaa"
Write-Output " Admins:    lab-admin (delegated OU admin), mcm-admin, sql-admin"
Write-Output " gMSA:      gmsa-sqlsvc"
Write-Output " DNS Fwd:   168.63.129.16 (Azure internal DNS) -- all DCs"
if (-not [string]::IsNullOrWhiteSpace($EntraIdDomain)) {
    Write-Output " Entra ID:  $EntraIdDomain (strategy: $DomainStrategy)"
}
Write-Output "=========================================="

Stop-Transcript

# Redact the password from the transcript log. The RunCommand handler passes
# protectedParameters as command-line arguments, so the SvcPassword value
# appears in the transcript header (the "Command line:" field).
$logPath = "C:\WindowsTemp\ConfigureAD.log"
if ((Test-Path $logPath) -and -not [string]::IsNullOrWhiteSpace($SvcPassword)) {
    $raw = [System.IO.File]::ReadAllText($logPath)
    $redacted = $raw.Replace($SvcPassword, '********')
    [System.IO.File]::WriteAllText($logPath, $redacted)
}

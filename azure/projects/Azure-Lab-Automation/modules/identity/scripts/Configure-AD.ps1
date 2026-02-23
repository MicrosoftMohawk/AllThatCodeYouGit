<#
.SYNOPSIS
    Configure Active Directory — OUs, Security Groups, Service Accounts, gMSA
    Runs as a VM RunCommand on the first domain controller after forest promotion.

.PARAMETER DomainName
    Fully qualified domain name (e.g., azlab.local)

.PARAMETER SvcPassword
    Password for service accounts (passed as protectedParameter)
#>
param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$SvcPassword
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
# Create OU Structure
# ============================================================================
Write-Output "Creating OU structure..."
$ous = @(
    @{ Name = 'Lab Accounts';       Parent = $domainDN }
    @{ Name = 'Service Accounts';   Parent = "OU=Lab Accounts,$domainDN" }
    @{ Name = 'Lab Groups';         Parent = $domainDN }
    @{ Name = 'Lab Servers';        Parent = $domainDN }
    @{ Name = 'SQL Servers';        Parent = "OU=Lab Servers,$domainDN" }
    @{ Name = 'App Servers';        Parent = "OU=Lab Servers,$domainDN" }
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
    @{ Name = 'GRP-DomainAdmins-Lab'; Description = 'Lab domain administrators' }
    @{ Name = 'GRP-SQLAdmins';        Description = 'SQL Server administrators' }
    @{ Name = 'GRP-AppAdmins';        Description = 'Application server administrators' }
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
    @{ Name = 'svc-appadmin'; Desc = 'Application Admin service account'; Groups = @('GRP-AppAdmins', 'GRP-DomainAdmins-Lab') }
    @{ Name = 'svc-sqlsvc';    Desc = 'SQL Server service account';     Groups = @('GRP-SQLAdmins') }
    @{ Name = 'svc-sqlagent';  Desc = 'SQL Agent service account';      Groups = @('GRP-SQLAdmins') }
    @{ Name = 'svc-appnaa';   Desc = 'Application Network Access Account';     Groups = @('GRP-AppAdmins') }
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
    }
    # Add to groups
    foreach ($grp in $svc.Groups) {
        Add-ADGroupMember -Identity $grp -Members $svc.Name -ErrorAction SilentlyContinue
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
# Create Group Managed Service Account (gMSA) for SQL Server
# ============================================================================
Write-Output "Creating gMSA: gmsa-sqlsvc..."
try {
    # Create KDS Root Key — use EffectiveTime in the past for lab (immediate effect)
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
Write-Output " OUs:       Lab Accounts, Service Accounts, Lab Groups, Lab Servers, SQL Servers, App Servers"
Write-Output " Groups:    GRP-DomainAdmins-Lab, GRP-SQLAdmins, GRP-AppAdmins, GRP-ServerAdmins, GRP-DomainJoin"
Write-Output " Accounts:  svc-domjoin, svc-appadmin, svc-sqlsvc, svc-sqlagent, svc-appnaa"
Write-Output " gMSA:      gmsa-sqlsvc"
Write-Output "=========================================="

Stop-Transcript

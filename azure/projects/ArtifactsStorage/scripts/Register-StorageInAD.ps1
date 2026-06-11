<#
.SYNOPSIS
    Register an Azure Storage Account as a computer object in on-premises AD.
    This enables Kerberos-based SMB authentication for domain-joined clients.

.DESCRIPTION
    Creates (or updates) a computer account in Active Directory that represents
    the Azure Storage account.  Sets the account password to the storage account's
    kerb1 key and enables AES256, following Microsoft's documented computer-account
    method.  For a computer account the default host-based Kerberos salt is used,
    which Azure Files derives from the registered samAccountName — so no ktpass /
    UPN-remap salt manipulation is needed (and using it breaks ticket decryption).

    This script is designed to run on a Domain Controller via
    'az vm run-command invoke'.  deploy.ps1 calls it automatically.

.PARAMETER StorageAccountName
    Name of the Azure Storage account (e.g., artifactsstgujl67iqq77x6).

.PARAMETER StorageKerbKey
    Base64-encoded Kerberos key (kerb1) from the storage account.
    Passed as a protectedParameter from deploy.ps1.

.PARAMETER DomainName
    FQDN of the AD domain (e.g., azlab.local).

.PARAMETER OUPath
    Distinguished Name of the OU to create the computer account in.
    Default: CN=Computers,<domain DN>

.NOTES
    Outputs a JSON object with domainGuid, domainSid, azureStorageSid, and
    netBiosDomainName for consumption by deploy.ps1.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$StorageKerbKey,

    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [string]$OUPath = ''
)

$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory

# ── Derive values ─────────────────────────────────────────────────────────────
$domain = Get-ADDomain -Identity $DomainName
$domainGuid = $domain.ObjectGuid.ToString()
$domainSid = $domain.DomainSID.Value
$forestName = $domain.Forest
$netBios = $domain.NetBIOSName

# SAM account name: max 15 chars + trailing $
$samName = if ($StorageAccountName.Length -gt 15) {
    $StorageAccountName.Substring(0, 15)
} else {
    $StorageAccountName
}

# SPN for Azure Files SMB
$spn = "cifs/$StorageAccountName.file.core.windows.net"

# OU -- default to CN=Computers if not specified
if ([string]::IsNullOrWhiteSpace($OUPath)) {
    $OUPath = "CN=Computers,$($domain.DistinguishedName)"
}

# Convert the storage Kerberos key to a SecureString password.
# The key from Azure (kerb1) is a base64 string — use it directly as the
# computer account password.  This matches what Azure validates when issuing
# Kerberos tickets.  Do NOT base64-decode it first.
$securePassword = ConvertTo-SecureString -String $StorageKerbKey -AsPlainText -Force

# ── Create or update the computer account ─────────────────────────────────────
$existingComputer = Get-ADComputer -Filter "SamAccountName -eq '$samName$'" -ErrorAction SilentlyContinue

if ($existingComputer) {
    Write-Host "Computer account '$samName' already exists -- updating password and SPN."
    Set-ADAccountPassword -Identity $existingComputer -Reset -NewPassword $securePassword
    Set-ADComputer -Identity $existingComputer -ServicePrincipalNames @{Replace = @($spn)}
    $computer = Get-ADComputer -Identity $existingComputer -Properties SID
} else {
    Write-Host "Creating computer account '$samName' in $OUPath"
    New-ADComputer `
        -Name $samName `
        -SamAccountName "$samName$" `
        -Path $OUPath `
        -ServicePrincipalNames @($spn) `
        -AccountPassword $securePassword `
        -Enabled $true `
        -Description "Azure Storage account for Azure Files SMB -- $StorageAccountName"

    $computer = Get-ADComputer -Identity $samName -Properties SID
}

# ── Configure AES256 encryption (computer-account method) ─────────────────────
# Per Microsoft guidance for a COMPUTER account, the Kerberos salt is the default
# host-based salt, which Azure Files derives from the registered samAccountName.
# Do NOT use ktpass or remap the UPN to the cifs SPN principal: that forces a
# different (cifs-principal) salt, so the AES256 key Azure holds no longer matches
# the key the DC issues tickets with.  The mount then fails with "System error 86"
# (or a credential prompt) because Azure Files can't decrypt the Kerberos ticket.
# A cifs UPN also contains '/', which is invalid for an AD principal.
# The account password was already set to the kerb1 key above (default salt).

# Computer accounts must not carry a UPN.  Clear any stale value left by older
# registration logic (e.g. a previous ktpass-based run).
$currentUpn = (Get-ADComputer -Identity $computer -Properties userPrincipalName).userPrincipalName
if (-not [string]::IsNullOrWhiteSpace($currentUpn)) {
    Set-ADComputer -Identity $computer -Clear userPrincipalName
    Write-Host "Cleared stale UPN: $currentUpn"
}

# Advertise AES256 only (equivalent to msDS-SupportedEncryptionTypes = 16).
Set-ADComputer -Identity $computer -KerberosEncryptionType AES256
Write-Host "KerberosEncryptionType = AES256"

# Re-assert the password to the kerb1 key so the AES256 keys are (re)derived with
# the correct default computer salt after setting the encryption type.
Set-ADAccountPassword -Identity $computer -Reset -NewPassword $securePassword
Write-Host "Password set to kerb1 key (default computer salt)."

# Flush the KDC's cached key material so it issues tickets with the new key.
Restart-Service kdc -Force
Write-Host "KDC service restarted (flushed cached key material)"

# Replicate to all DCs so every KDC can issue valid service tickets
repadmin /syncall /AdeP 2>&1 | Out-Null
Write-Host "AD replication triggered"

$azureStorageSid = $computer.SID.Value

# ── Output results as JSON ────────────────────────────────────────────────────
$result = @{
    domainGuid        = $domainGuid
    domainSid         = $domainSid
    forestName        = $forestName
    netBiosDomainName = $netBios
    azureStorageSid   = $azureStorageSid
    computerName      = $samName
    accountType       = 'Computer'
    spn               = $spn
} | ConvertTo-Json -Compress

Write-Host "AD_REGISTRATION_RESULT=$result"

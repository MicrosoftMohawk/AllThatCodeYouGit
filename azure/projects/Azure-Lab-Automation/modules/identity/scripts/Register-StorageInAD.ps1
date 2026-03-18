<#
.SYNOPSIS
    Register an Azure Storage Account as a computer object in on-premises AD.
    This enables Kerberos-based SMB authentication for domain-joined clients.

.DESCRIPTION
    Creates (or updates) a computer account in Active Directory that represents
    the Azure Storage account.  Uses ktpass to set the AES256 Kerberos key with
    the correct salt (based on the cifs SPN principal), ensuring Azure Files can
    decrypt Kerberos tickets issued by the on-premises DC.

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

# ── Fix AES256 salt mismatch ──────────────────────────────────────────────────
# When Set-ADAccountPassword sets the password, the DC derives AES keys using
# a salt based on the computer account's default principal:
#   <REALM>host<samName_no_$>.<domain>  →  e.g. TS11.LABhostartifactsstgujl.ts11.lab
#
# Azure Files derives its AES keys using a salt based on the cifs SPN:
#   <REALM><cifs/storage.file.core.windows.net>
#
# These salts differ → different AES keys → Kerberos ticket decryption fails
# (error 1396 "target account name is incorrect").
#
# Fix: Use ktpass to set the account's UPN to the cifs principal.  This changes
# the salt the DC uses for AES key derivation to match Azure's expectation.
# ktpass also resets the password with the new salt in one operation.

$realm = $DomainName.ToUpper()
$principal = "$spn@$realm"

Write-Host "Setting AES256 key via ktpass (principal: $principal)..."

# ktpass caveats:
#   1. The kerb key often starts with '/' which ktpass mis-parses as a switch.
#      Fix: pass the key via an environment variable expanded by cmd.exe inside
#      double-quotes so it's treated as a single token.
#   2. ktpass prompts "Do you want to continue? (Y/N)" when remapping a principal.
#      Fix: pipe 'echo y' via cmd.exe.
#   3. /out NUL can hang on some systems; use a temp keytab file and delete it.
$keytabPath = Join-Path $env:TEMP "stg_$([guid]::NewGuid().ToString('N').Substring(0,8)).keytab"
$env:_KTPASS_KEY = $StorageKerbKey
try {
    # The 2>&1 MUST be inside the cmd string (handled by cmd.exe), not on the
    # PowerShell invocation.  ktpass writes its success message to stderr, and
    # PS 5.1 with $ErrorActionPreference='Stop' treats stderr from native
    # commands captured via PS-level 2>&1 as a terminating NativeCommandError.
    $ktpassCmd = 'echo y | ktpass /out "{0}" /princ {1} /mapuser "{2}\{3}$" /crypto AES256-SHA1 /pass "%_KTPASS_KEY%" /ptype KRB5_NT_PRINCIPAL 2>&1' -f $keytabPath, $principal, $netBios, $samName
    $ktpassResult = cmd /c $ktpassCmd
    $ktpassExit = $LASTEXITCODE
    Write-Host ($ktpassResult | Out-String)
} catch {
    $ktpassExit = 1
    Write-Host "ktpass exception: $_"
} finally {
    $env:_KTPASS_KEY = $null
    Remove-Item $keytabPath -Force -ErrorAction SilentlyContinue
}

if ($ktpassExit -ne 0) {
    Write-Host "ktpass failed (exit $ktpassExit) -- falling back to UPN + Set-ADAccountPassword..."
    Set-ADComputer -Identity $computer -Replace @{userPrincipalName = $principal}
    Set-ADAccountPassword -Identity $computer -Reset -NewPassword $securePassword
}

# Ensure only AES256 encryption is advertised
Set-ADComputer -Identity $computer -Replace @{'msDS-SupportedEncryptionTypes' = 16}

# Flush the KDC's cached key material.  The password was set twice — first by
# New-ADComputer/Set-ADAccountPassword (default salt) then by ktpass (correct
# salt).  The KDC may cache the first key and not pick up the ktpass update
# until the service restarts.
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

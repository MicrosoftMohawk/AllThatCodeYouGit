// ============================================================================
// Module: Domain Join - Join a Windows VM to an Active Directory domain
//
// Uses the JsonADDomainExtension (Microsoft.Compute.JsonADDomainExtension)
// to join the target VM to the specified AD domain.
//
// A RunCommand-based readiness check runs first: it flushes the DNS cache and
// polls until an actual domain controller can be LOCATED and CONTACTED via the
// DC locator (nltest /dsgetdc), not merely until the SRV record resolves. This
// prevents the common Azure timing issue where the SRV record already exists in
// DNS but the DC is not yet advertising (e.g. a freshly promoted replica DC
// whose SYSVOL is still replicating), which otherwise fails the join with
// error 0x54b (ERROR_NO_SUCH_DOMAIN).
//
// Prerequisites:
//   - The domain must be reachable from the VM's subnet (VNet DNS set to DCs).
//   - The join credential must have permission to create computer objects
//     (e.g., the svc-domjoin account created by configureAD.bicep).
//
// By default the VM is joined to the default Computers container. To place it
// in a specific OU, set the ouPath parameter.
// ============================================================================

@description('Name of the existing VM to domain-join')
param vmName string

@description('Azure region')
param location string

@description('Fully qualified domain name (e.g., azlab.local)')
param domainName string

@description('UPN or DOMAIN\\user with permission to join machines to the domain')
param domainJoinUser string

@description('Password for the domain join account')
@secure()
param domainJoinPassword string

@description('Optional OU path for the computer object (e.g., OU=SQL Servers,OU=Lab Servers,DC=azlab,DC=local). Leave empty for default Computers container.')
param ouPath string = ''

@description('Tags')
param tags object = {}

// Domain join options bitmask:
//   0x00000001 = Join domain
//   0x00000002 = Account create (create the computer account if it doesn't exist)
// Combined = 3
var domainJoinOptions = 3

// ---------------------------------------------------------------------------
// Step 1 - Domain Controller Readiness Check (RunCommand)
// Flush the DNS cache, then poll until an actual, live domain controller can be
// LOCATED and CONTACTED -- not just until the SRV record resolves. The DC
// locator (nltest /dsgetdc) performs the same DsGetDcName call the domain-join
// extension uses, so this only succeeds when a real join would succeed. It
// closes the timing gap where the SRV record already exists in DNS but the DC
// is not yet advertising (e.g. a freshly promoted replica DC whose SYSVOL is
// still replicating), which otherwise fails the join with error 0x54b
// (ERROR_NO_SUCH_DOMAIN). Retries up to 60 times (15 s apart ~ 15 min).
// ---------------------------------------------------------------------------
resource dnsReadyCheck 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  name: '${vmName}/DnsReadyCheck'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 1200
    source: {
      script: '''
        param([string]$DomainName)

        $srvTarget   = "_ldap._tcp.dc._msdcs.$DomainName"
        $maxAttempts = 60
        $sleepSec    = 15

        Write-Output "Validating domain controller availability for: $DomainName"
        Write-Output "SRV target: $srvTarget"

        for ($i = 1; $i -le $maxAttempts; $i++) {
            Clear-DnsClientCache

            # Stage 1 - the SRV record must resolve (a DC has registered in DNS).
            $srv = Resolve-DnsName -Name $srvTarget -Type SRV -ErrorAction SilentlyContinue
            if (-not $srv) {
                Write-Output "Attempt $i/${maxAttempts}: SRV record not resolvable yet, retrying in ${sleepSec}s..."
                Start-Sleep -Seconds $sleepSec
                continue
            }

            # Stage 2 - the DC locator must find AND contact a live, advertising
            # DC. nltest issues the same DsGetDcName call the join uses, so a
            # success here means the join will not fail with 0x54b.
            $dcInfo = & nltest.exe "/dsgetdc:$DomainName" "/force" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Output "DC locator succeeded on attempt $i -- a live DC for $DomainName is reachable."
                Write-Output $dcInfo
                exit 0
            }

            Write-Output "Attempt $i/${maxAttempts}: SRV resolves but no live DC reachable yet (nltest exit $LASTEXITCODE), retrying in ${sleepSec}s..."
            Start-Sleep -Seconds $sleepSec
        }

        throw "No reachable domain controller for '$DomainName' after $maxAttempts attempts ($($maxAttempts * $sleepSec) seconds). The DC may still be completing promotion / SYSVOL replication, or DNS/network connectivity to the DC is misconfigured."
      '''
    }
    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Step 2 - Domain Join Extension
// Runs only after the DNS readiness check succeeds.
// ---------------------------------------------------------------------------
resource domainJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: '${vmName}/JoinDomain'
  location: location
  tags: tags
  dependsOn: [dnsReadyCheck]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainName
      OUPath: ouPath
      User: domainJoinUser
      Restart: 'true'
      Options: domainJoinOptions
    }
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
}

output extensionId string = domainJoinExtension.id

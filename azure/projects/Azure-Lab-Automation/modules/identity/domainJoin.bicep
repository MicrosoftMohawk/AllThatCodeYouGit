// ============================================================================
// Module: Domain Join — Join a Windows VM to an Active Directory domain
//
// Uses the JsonADDomainExtension (Microsoft.Compute.JsonADDomainExtension)
// to join the target VM to the specified AD domain.
//
// A RunCommand-based DNS readiness check runs first, clearing the DNS client
// cache and polling for the domain's SRV records. This prevents the common
// Azure timing issue where member VMs cannot yet reach the DC's DNS service
// even though the DCs are fully promoted.
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
// Step 1 — DNS Readiness Check (RunCommand)
// Flush the local DNS cache and poll until the domain's LDAP SRV record is
// resolvable. Retries up to 30 times (10 s apart ≈ 5 min) before failing.
// ---------------------------------------------------------------------------
resource dnsReadyCheck 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  name: '${vmName}/DnsReadyCheck'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 600
    source: {
      script: '''
        param([string]$DomainName)

        $srvTarget = "_ldap._tcp.dc._msdcs.$DomainName"
        $maxAttempts = 30
        $sleepSec    = 10

        Write-Output "Validating DNS resolution for domain: $DomainName"
        Write-Output "Looking up SRV record: $srvTarget"

        for ($i = 1; $i -le $maxAttempts; $i++) {
            Clear-DnsClientCache
            $srv = Resolve-DnsName -Name $srvTarget -Type SRV -ErrorAction SilentlyContinue
            if ($srv) {
                Write-Output "DNS ready on attempt $i — found DC: $($srv[0].NameTarget)"
                exit 0
            }
            Write-Output "Attempt $i/${maxAttempts}: no response yet, retrying in ${sleepSec}s..."
            Start-Sleep -Seconds $sleepSec
        }

        throw "DNS resolution for $DomainName failed after $maxAttempts attempts ($($maxAttempts * $sleepSec) seconds). SRV target: $srvTarget"
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
// Step 2 — Domain Join Extension
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

// ============================================================================
// Module: Entra ID Join -- AADLoginForWindows Extension
//
// Applies the AADLoginForWindows VM extension to enable Entra ID-based login.
//
// A RunCommand-based DNS readiness check runs first, clearing the DNS client
// cache and polling until login.microsoftonline.com resolves. This prevents
// failures when the VNet DNS servers (domain controllers) have not yet
// configured their DNS forwarder to Azure DNS (168.63.129.16).
//
// For pure Entra ID join: Apply WITHOUT domain join. The extension handles
// full Entra ID device registration.
//
// After the extension is installed, assign the "Virtual Machine Administrator
// Login" or "Virtual Machine User Login" RBAC role to users who need to sign
// in with Entra ID credentials.
// ============================================================================

@description('Name of the existing VM to enable Entra ID login on')
param vmName string

@description('Azure region')
param location string

@description('Tags')
param tags object = {}

// ---------------------------------------------------------------------------
// Step 1 - Entra DNS Readiness Check (RunCommand)
// Flush the local DNS cache and poll until login.microsoftonline.com resolves.
// Retries up to 30 times (10 s apart ~ 5 min) before failing.
// ---------------------------------------------------------------------------
resource entraDnsCheck 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  name: '${vmName}/EntraDnsCheck'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 600
    source: {
      script: '''
        $targets = @('login.microsoftonline.com', 'enterpriseregistration.windows.net')
        $maxAttempts = 30
        $sleepSec = 10

        Clear-DnsClientCache
        Write-Output "Checking Entra ID DNS readiness..."

        foreach ($target in $targets) {
            $resolved = $false
            for ($i = 1; $i -le $maxAttempts; $i++) {
                Clear-DnsClientCache
                $result = Resolve-DnsName -Name $target -Type A -ErrorAction SilentlyContinue
                if ($result) {
                    Write-Output "DNS ready on attempt $i -- resolved $target to $($result[0].IPAddress)"
                    $resolved = $true
                    break
                }
                Write-Output "Attempt $i/$maxAttempts -- $target not yet resolvable, waiting ${sleepSec}s..."
                Start-Sleep -Seconds $sleepSec
            }
            if (-not $resolved) {
                Write-Output "FAILED: Could not resolve $target after $maxAttempts attempts"
                Write-Output "DNS servers configured on this VM:"
                Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table -AutoSize | Out-String | Write-Output
                exit 1
            }
        }

        Write-Output "All Entra ID endpoints resolvable -- proceeding with AAD join"
        exit 0
      '''
    }
  }
}

// ---------------------------------------------------------------------------
// Step 2 - AADLoginForWindows Extension
// ---------------------------------------------------------------------------
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: '${vmName}/AADLoginForWindows'
  location: location
  tags: tags
  dependsOn: [entraDnsCheck]
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
    settings: {
      mdmId: ''
    }
  }
}

output extensionId string = aadLogin.id

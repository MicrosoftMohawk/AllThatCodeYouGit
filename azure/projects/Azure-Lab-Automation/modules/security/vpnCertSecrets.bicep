// ============================================================================
// Module: VPN Certificate Secrets (control-plane writer)
// Writes the P2S VPN certificate secrets (and optionally the admin password)
// into an EXISTING Key Vault. Uses the ARM control plane so the write succeeds
// even when the vault is private and the caller is not on the VPN.
// ============================================================================

@description('Name of the existing Key Vault')
param keyVaultName string

@description('Base64-encoded P2S VPN root certificate public key')
param vpnRootCertData string

@description('Base64-encoded P2S VPN client certificate PFX')
@secure()
param vpnClientCertData string

@description('Admin password to store (only when updateAdminPassword is true)')
@secure()
param adminPassword string = ''

@description('When true, also (re)writes the vm-admin-password secret')
param updateAdminPassword bool = false

@description('Tags to apply to the secrets')
param tags object = {}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource vpnRootCertSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'vpn-root-cert'
  tags: tags
  properties: {
    value: vpnRootCertData
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

resource vpnClientCertSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'vpn-client-cert-pfx'
  tags: tags
  properties: {
    value: vpnClientCertData
    contentType: 'application/x-pkcs12'
    attributes: {
      enabled: true
    }
  }
}

resource adminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (updateAdminPassword && !empty(adminPassword)) {
  parent: kv
  name: 'vm-admin-password'
  tags: tags
  properties: {
    value: adminPassword
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

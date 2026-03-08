# Artifacts Storage

Private Azure Files share for storing lab artifacts — ISOs, installers, configuration
files, and other assets used during post-deployment setup.

This project is **standalone** and has no dependency on the Azure Lab Automation
deployment, other than referencing the lab VNet for Private Endpoint connectivity
and the Domain Controller for AD DS registration.

## Architecture

| Component | Purpose |
|-----------|---------|
| Storage Account | StorageV2, Standard_LRS, TLS 1.2, shared keys disabled |
| Azure Files Share | `artifacts` share (default 100 GiB quota) |
| Private Endpoint | Connects storage to the lab VNet — no public access |
| Private DNS Zone | `privatelink.file.core.windows.net` linked to lab VNet |
| AD DS Identity Auth | On-prem AD Kerberos for SMB from domain-joined VMs |
| Default Share Permission | `StorageFileDataSmbShareContributor` for all authenticated domain users |
| RBAC | Optional Entra ID RBAC for deployer (az CLI / OAuth access) |

**No shared keys. No SAS tokens.**

Two access paths:
- **Domain-joined VMs**: Kerberos SMB mount via on-premises AD DS authentication
- **VPN workstations**: az CLI with `--auth-mode login` (OAuth, supports MFA/passkey)

## Prerequisites

- Azure CLI 2.20+ with Bicep CLI
- An existing lab deployment (provides the VNet, PE subnet, and Domain Controller)
- The lab VNet must include a `snet-pe` subnet for private endpoints
- DC01 must be running and reachable for AD DS registration

## File Structure

```
ArtifactsStorage/
├── main.bicep              # Subscription-scoped orchestrator
├── deploy.ps1              # Interactive deployment wrapper
├── README.md               # This file
├── modules/
│   ├── storageAccount.bicep    # Storage account + file share + AD DS config
│   ├── privateEndpoint.bicep   # PE + Private DNS Zone + VNet link
│   └── rbacAssignment.bicep    # RBAC role assignment
└── scripts/
    └── Register-StorageInAD.ps1  # AD computer account registration (runs on DC01)
```

## Usage

### Deploy (auto-detect lab VNet)

```powershell
.\deploy.ps1 -NamePrefix artifacts -Location eastus -LabBaseName azlab
```

The script auto-discovers the lab VNet (`azlab-vnet`) and PE subnet (`snet-pe`)
from the lab's network resource group.

### Deploy (explicit IDs)

```powershell
.\deploy.ps1 -NamePrefix artifacts -Location eastus `
    -LabVnetId "/subscriptions/.../providers/Microsoft.Network/virtualNetworks/azlab-vnet" `
    -PeSubnetId "/subscriptions/.../subnets/snet-pe"
```

### Destroy

```powershell
.\deploy.ps1 -NamePrefix artifacts -Destroy
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `NamePrefix` | string | Yes | — | Resource name prefix (max 10 chars) |
| `Location` | string | Yes* | — | Azure region (*not required for `-Destroy`) |
| `LabBaseName` | string | Yes** | — | Lab base name for auto-detection and AD DS registration |
| `LabVnetId` | string | No | — | Full VNet resource ID (if no auto-detect) |
| `PeSubnetId` | string | No | — | Full PE subnet resource ID (if no auto-detect) |
| `ShareQuotaGiB` | int | No | 100 | File share quota in GiB |
| `SubscriptionId` | string | No | — | Target subscription |
| `DomainName` | string | No | auto | AD domain FQDN (queried from DC01 if not set) |
| `SkipADDS` | switch | No | — | Skip AD DS registration (infra-only redeploy) |
| `Destroy` | switch | No | — | Delete all artifacts resources |

**Required for AD DS registration (Kerberos SMB). If only explicit VNet/subnet IDs are provided, AD DS registration is skipped.

## Accessing the Share

All access requires VPN or VNet connectivity — the storage account has no public endpoint.

### From VPN workstation (az CLI + OAuth/MFA)

Use az CLI with `--auth-mode login` which authenticates via browser-based OAuth.
This supports MFA, passkeys, and Conditional Access — no domain join required.

```powershell
# Upload a file
az storage file upload --account-name <name> --share-name artifacts --source ./myfile.iso --auth-mode login

# List files
az storage file list --account-name <name> --share-name artifacts --auth-mode login -o table

# Download a file
az storage file download --account-name <name> --share-name artifacts --path myfile.iso --dest ./myfile.iso --auth-mode login
```

> **Note:** SMB mount (`net use`) does **not** work from a non-domain-joined workstation.
> The az CLI is the supported access method for VPN workstations.

### From domain-joined VM (Kerberos SMB)

Domain-joined VMs authenticate via Kerberos — no password prompt:

```cmd
net use Z: \\<storageaccount>.file.core.windows.net\artifacts
```

This works because:
1. The storage account is registered as a computer account in AD
2. The DC issues a Kerberos ticket for `cifs/<account>.file.core.windows.net`
3. `defaultSharePermission` grants all authenticated domain users Contributor access

#### Troubleshooting Kerberos mount

If `net use` prompts for credentials or fails:

1. **Verify domain membership**: `systeminfo | findstr /i "domain"`
2. **Check Kerberos tickets**: `klist` (look for a `cifs/` ticket after mount attempt)
3. **Verify DNS resolution**: `nslookup <account>.file.core.windows.net` should resolve
   to the Private Endpoint IP (10.0.250.x), not a public IP
4. **Verify AD registration**: On DC01, run `Get-ADComputer -Identity <storageaccount>`
5. **Check SPN**: `Get-ADComputer -Identity <storageaccount> -Properties ServicePrincipalName`

### NTFS ACLs (optional)

After mounting, you can set file/directory-level NTFS permissions from a domain-joined VM:

```cmd
icacls Z:\ /grant "AZLAB\GRP-ServerAdmins:(OI)(CI)M"
```

## How AD DS Authentication Works

The deploy script performs these steps automatically after the Bicep deployment:

1. **Generates a Kerberos key** (`kerb1`) on the storage account
2. **Creates a computer account** in AD (on DC01) with the storage account name
   - Sets the computer password to the Kerberos key
   - Registers SPN: `cifs/<account>.file.core.windows.net`
   - Enables AES256 encryption
3. **Configures the storage account** with AD DS identity properties
   (domain GUID, domain SID, computer SID)
4. **Sets `defaultSharePermission`** to `StorageFileDataSmbShareContributor`
   so all authenticated domain users get Contributor access (no per-user RBAC needed)
5. **Re-disables shared key access** — the Kerberos key is retained internally
   for ticket validation, but cannot be used for direct SMB or REST authentication

## Security

- **No public network access** — all traffic flows through the Private Endpoint
- **No shared key access** — storage account keys cannot be used for data-plane auth
- **No SAS tokens** — only AD DS Kerberos or Entra ID OAuth authentication
- **AD DS Kerberos** — domain-joined VMs authenticate via Kerberos tickets (no passwords over the wire)
- **TLS 1.2 minimum** for all connections
- **Private DNS** — `<account>.file.core.windows.net` resolves to the PE private IP
  when queried from the linked VNet (including VPN clients)
- **AES256 encryption** for Kerberos tickets

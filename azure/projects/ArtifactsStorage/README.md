# Artifacts Storage

Private Azure Files share for storing lab artifacts — ISOs, installers, configuration
files, and other assets used during post-deployment setup.

This project is **standalone** and has no dependency on the Azure Lab Automation
deployment, other than referencing the lab VNet for Private Endpoint connectivity.

## Architecture

| Component | Purpose |
|-----------|---------|
| Storage Account | StorageV2, Standard_LRS, TLS 1.2, Entra ID RBAC only |
| Azure Files Share | `artifacts` share (default 100 GiB quota) |
| Private Endpoint | Connects storage to the lab VNet — no public access |
| Private DNS Zone | `privatelink.file.core.windows.net` linked to lab VNet |
| RBAC | Storage File Data SMB Share Contributor for deployer |

**No shared keys. No SAS tokens. No AD DS integration.**

Access is exclusively via Entra ID credentials over a private network connection
(P2S VPN, Bastion, or VNet-connected VMs).

## Prerequisites

- Azure CLI 2.20+ with Bicep CLI
- An existing lab deployment (provides the VNet and PE subnet)
- The lab VNet must include a `snet-pe` subnet for private endpoints

## File Structure

```
ArtifactsStorage/
├── main.bicep              # Subscription-scoped orchestrator
├── deploy.ps1              # Interactive deployment wrapper
├── README.md               # This file
└── modules/
    ├── storageAccount.bicep    # Storage account + file share
    ├── privateEndpoint.bicep   # PE + Private DNS Zone + VNet link
    └── rbacAssignment.bicep    # RBAC role assignment
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
| `LabBaseName` | string | No | — | Lab base name for auto-detection |
| `LabVnetId` | string | No | — | Full VNet resource ID (if no auto-detect) |
| `PeSubnetId` | string | No | — | Full PE subnet resource ID (if no auto-detect) |
| `ShareQuotaGiB` | int | No | 100 | File share quota in GiB |
| `SubscriptionId` | string | No | — | Target subscription |
| `Destroy` | switch | No | — | Delete all artifacts resources |

## Accessing the Share

All access requires VPN or VNet connectivity — the storage account has no public endpoint.

### az CLI (from VPN-connected workstation)

```powershell
# Upload a file
az storage file upload --account-name <name> --share-name artifacts --source ./myfile.iso --auth-mode login

# List files
az storage file list --account-name <name> --share-name artifacts --auth-mode login -o table

# Download a file
az storage file download --account-name <name> --share-name artifacts --path myfile.iso --dest ./myfile.iso --auth-mode login
```

### SMB Mount (from VNet-connected VM)

```cmd
net use Z: \\<storageaccount>.file.core.windows.net\artifacts
```

Uses the logged-in Windows identity (Entra ID or domain-joined with Entra trust).

## Security

- **No public network access** — all traffic flows through the Private Endpoint
- **No shared key access** — storage account keys are disabled
- **No SAS tokens** — only Entra ID RBAC authentication
- **TLS 1.2 minimum** for all connections
- **Private DNS** — `<account>.file.core.windows.net` resolves to the PE private IP
  when queried from the linked VNet (including VPN clients)

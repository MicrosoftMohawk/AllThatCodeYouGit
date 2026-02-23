# Azure Global Lab — Bicep Deployment

Automated infrastructure-as-code deployment for a **modular Azure lab** environment. Deploys a multi-tier hierarchy with a Central Administration Site (CAS), 3 child primary sites across multiple subnets simulating global site dispersion, SQL Server infrastructure including an Always On Availability Group (AOAG), Active Directory domain controllers, and a Point-to-Site VPN Gateway for remote connectivity. Designed to expand with additional workload modules over time.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Azure VNet: 10.0.0.0/16                                                │
│                                                                          │
│  ┌─────────────────────┐  ┌────────────────────────────────────────────┐ │
│  │ AzureBastionSubnet  │  │ snet-ad (10.0.1.0/24)                     │ │
│  │ 10.0.0.0/26         │  │   DC01 (10.0.1.4)  DC02 (10.0.1.5)       │ │
│  │   Azure Bastion     │  │                                            │ │
│  └─────────────────────┘  └────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─────────────────────┐  ┌────────────────────────────────────────────┐ │
│  │ GatewaySubnet       │  │ P2S VPN Client Pool: 172.16.0.0/24        │ │
│  │ 10.0.255.0/27       │  │   IKEv2 + SSTP — Certificate Auth          │ │
│  │   VPN Gateway       │  │   Self-signed root + client cert           │ │
│  └─────────────────────┘  └────────────────────────────────────────────┘ │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐│
│  │ snet-main (10.0.20.0/24)  — Main Site / HQ                         ││
│  │   CAS01        PrimaryA        SQL-CAS        SQL-PrimA            ││
│  └──────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐│
│  │ snet-site1 (10.0.30.0/24)  — Remote Site 1                         ││
│  │   PrimaryB        SQL-PrimB                                         ││
│  └──────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐│
│  │ snet-site2 (10.0.40.0/24)  — Remote Site 2 (AOAG)                  ││
│  │   PrimaryC        SQL-PrimC01 ──┐                                   ││
│  │                   SQL-PrimC02 ──┤ AOAG + ILB Listener (10.0.40.10) ││
│  │                                 │ Cloud Witness (Storage Acct)      ││
│  └──────────────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────────┘
```

### VM Inventory (11 VMs total)

| VM Name | Role | Size | Subnet | Tier |
|---------|------|------|--------|------|
| `{base}-dc01` | Domain Controller | Standard_D2s_v5 | snet-ad | 1 |
| `{base}-dc02` | Domain Controller | Standard_D2s_v5 | snet-ad | 1 |
| `{base}-sqcs` | SQL Server (CAS DB) | Standard_D4s_v5 | snet-main | 2 |
| `{base}-sqpa` | SQL Server (PrimA DB) | Standard_D4s_v5 | snet-main | 2 |
| `{base}-sqpb` | SQL Server (PrimB DB) | Standard_D4s_v5 | snet-site1 | 2 |
| `{base}-sqc1` | SQL AOAG Node 1 (PrimC) | Standard_D8s_v5 | snet-site2 | 2 |
| `{base}-sqc2` | SQL AOAG Node 2 (PrimC) | Standard_D8s_v5 | snet-site2 | 2 |
| `{base}-cas` | CAS Server | Standard_D4s_v5 | snet-main | 3 |
| `{base}-prma` | Child Primary A | Standard_D4s_v5 | snet-main | 3 |
| `{base}-prmb` | Child Primary B | Standard_D4s_v5 | snet-site1 | 3 |
| `{base}-prmc` | Child Primary C | Standard_D4s_v5 | snet-site2 | 3 |

---

## Prerequisites

| Requirement | Minimum Version | Check Command |
|-------------|-----------------|---------------|
| **Azure CLI** | 2.20.0+ | `az version` |
| **Bicep CLI** | (bundled with Az CLI) | `az bicep version` |
| **Azure Subscription** | — | `az account list -o table` |
| **RBAC** | Contributor on subscription | `az role assignment list --assignee <upn>` |

### VM Quota Requirements

Ensure your subscription has sufficient vCPU quota in the target region:

| VM Size | vCPUs each | Count | Total vCPUs |
|---------|-----------|-------|-------------|
| Standard_D2s_v5 | 2 | 2 (DCs) | 4 |
| Standard_D4s_v5 | 4 | 7 (SQL standalone + App) | 28 |
| Standard_D8s_v5 | 8 | 2 (SQL AOAG) | 16 |
| **Total** | | **11** | **48 vCPUs** |

Check quota:
```bash
az vm list-usage --location eastus --output table | grep -i "Standard DSv5"
```

### Install Prerequisites

```bash
# Install Azure CLI (Windows — winget)
winget install Microsoft.AzureCLI

# Install/Upgrade Bicep
az bicep install
az bicep upgrade

# Verify
az version
az bicep version
```

---

## Deployment Tiers

The deployment uses a **tiered** approach so you can deploy incrementally:

| Tier | What Gets Deployed | Use Case |
|------|-------------------|----------|
| **1** | VNet, Subnets, NSGs, Azure Bastion, VPN Gateway (P2S), 2 DCs (static IPs), Cloud Witness Storage, Key Vault, **AD DS automation** (forest promotion, OUs, groups, service accounts, gMSA, replica DC) | Set up core networking, VPN, and AD only |
| **2** | + 5 SQL VMs (with data disks), Availability Set, Internal Load Balancer | Add SQL infrastructure |
| **3** | + 4 Application VMs (CAS + 3 child primaries) | Full lab deployment |

Each tier is **cumulative** — Tier 3 includes everything from Tiers 1 and 2. You can deploy Tier 1 first, then redeploy with Tier 2 or 3 later — the deployment is idempotent.

---

## Quick Start

### 1. Clone / Download

```bash
git clone <repo-url>
cd "Azure Lab"
```

### 2. Deploy Using the PowerShell Wrapper (Recommended)

```powershell
# Full lab (all 3 tiers)
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 3

# Core networking and AD only (Tier 1)
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 1

# Preview changes without deploying
.\deploy.ps1 -BaseName azlab -Location eastus -WhatIf

# Deploy to a specific subscription
.\deploy.ps1 -BaseName azlab -Location eastus -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

The script will:
- Check for Az CLI and Bicep CLI (installs Bicep if missing)
- Validate your Azure login (opens browser if needed)
- Prompt for Key Vault Administrator (user UPN or Entra ID group)
- Compile and validate the Bicep template
- Auto-generate a secure admin password (stored in Key Vault)
- Prompt for the AD domain name
- Generate self-signed root CA + client certificates for VPN (P2S)
- Execute the deployment

### 3. Deploy Using Azure CLI Directly

```bash
# If you don't know your subscription ID:
az account list --output table
az account set --subscription "My Subscription Name"

# Deploy full lab
az deployment sub create \
  --location eastus \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters baseName='azlab' location='eastus' deploymentTier=3

# Deploy only Tier 1 (Core + AD)
az deployment sub create \
  --location eastus \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters baseName='azlab' location='eastus' deploymentTier=1 adminPassword='YourP@ssw0rd!'

# What-If preview
az deployment sub create \
  --location eastus \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters baseName='azlab' location='eastus' deploymentTier=3 \
  --what-if
```

### 4. Verify Deployment

```bash
# List all lab resource groups
az group list --tag env=lab --output table

# List all lab VMs
az vm list --query "[?tags.project=='azure-lab'].[name,resourceGroup,location]" --output table

# Get deployment outputs
az deployment sub show --name <deployment-name> --query properties.outputs
```

---

## File Structure

```
Azure-Lab/
├── README.md                              # This file
├── deploy.ps1                             # PowerShell wrapper (prereq checks + deploy)
├── Install-VpnCerts.ps1                   # Helper: install VPN certs on secondary machines
├── main.bicep                             # Subscription-scoped orchestrator
├── bicepconfig.json                       # Bicep linter / analyzer config
├── MECM-Azure-Global-Lab.ps1              # Original PowerShell script (reference)
├── certs/                                 # Auto-generated VPN certificates
│   ├── P2SRootCert.cer                    # Root CA public key (reused on redeploy)
│   ├── P2SClientCert.pfx                  # Client cert (password = admin password)
│   └── vpn-client/                        # Downloaded VPN client config (from helper script)
├── parameters/
│   └── main.bicepparam                    # Default parameter values (for direct az CLI use)
└── modules/
    ├── network/
    │   ├── vnet.bicep                     # VNet + subnets + NSGs + GatewaySubnet + custom DNS
    │   ├── bastion.bicep                  # Azure Bastion (Standard) + Public IP
    │   └── vpnGateway.bicep               # VPN Gateway (P2S, certificate auth) + Public IP
    ├── compute/
    │   ├── vm.bicep                       # Reusable Windows Server VM module
    │   ├── availabilitySet.bicep           # Availability Set for AOAG SQL nodes
    │   └── loadBalancer.bicep              # Internal Load Balancer for AOAG listener
    ├── storage/
    │   └── storageAccount.bicep           # Cloud Witness storage account
    ├── security/
    │   └── keyVault.bicep                 # Key Vault (password storage + RBAC assignment)
    └── identity/
        ├── promoteDC.bicep                # CSE: Promote DC01 as first DC (new forest)
        ├── configureAD.bicep              # RunCommand: OUs, groups, svc accounts, gMSA
        ├── replicaDC.bicep                # CSE: Promote DC02 as replica DC
        └── scripts/
            └── Configure-AD.ps1           # AD configuration script (loaded inline)
```

---

## Parameters Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `baseName` | string | `azlab` | Base name prefix for all resources (max 10 chars) |
| `location` | string | `eastus` | Azure region |
| `deploymentTier` | int | `3` | 1 = Core/AD, 2 = +SQL, 3 = +App servers (full) |
| `adminUsername` | string | `labadmin` | Local admin username for all VMs |
| `adminPassword` | securestring | — | Local admin password (auto-generated by deploy.ps1) |
| `domainName` | string | — | AD domain name (prompted by deploy.ps1, e.g., azlab.local) |
| `sizeDC` | string | `Standard_D2s_v5` | VM size for Domain Controllers |
| `sizeApp` | string | `Standard_D4s_v5` | VM size for CAS and Primary servers |
| `sizeSQL` | string | `Standard_D4s_v5` | VM size for standalone SQL VMs |
| `sizeSQLAoag` | string | `Standard_D8s_v5` | VM size for AOAG SQL VMs |
| `vnetAddressPrefix` | string | `10.0.0.0/16` | VNet address space |
| `snetBastionPrefix` | string | `10.0.0.0/26` | Azure Bastion subnet CIDR |
| `snetAdPrefix` | string | `10.0.1.0/24` | AD subnet CIDR |
| `snetMainPrefix` | string | `10.0.20.0/24` | Main site subnet CIDR |
| `snetSite1Prefix` | string | `10.0.30.0/24` | Site 1 subnet CIDR |
| `snetSite2Prefix` | string | `10.0.40.0/24` | Site 2 subnet CIDR |
| `snetGatewayPrefix` | string | `10.0.255.0/27` | GatewaySubnet CIDR for VPN Gateway |
| `vpnRootCertData` | string | (auto-generated) | Base64 root cert public key for P2S VPN |
| `vpnClientAddressPrefix` | string | `172.16.0.0/24` | P2S VPN client address pool CIDR |
| `deployerObjectId` | string | (prompted) | Entra ID object ID for Key Vault Administrator RBAC |
| `kvPrincipalType` | string | `User` | Principal type for KV RBAC: `User` or `Group` |
| `dc01Ip` | string | `10.0.1.4` | Static IP for DC01 |
| `dc02Ip` | string | `10.0.1.5` | Static IP for DC02 |
| `aoagListenerIp` | string | `10.0.40.10` | AOAG Listener IP (ILB frontend) |
| `imagePublisher` | string | `MicrosoftWindowsServer` | OS image publisher |
| `imageOffer` | string | `WindowsServer` | OS image offer |
| `imageSku` | string | `2022-datacenter-g2` | OS image SKU |
| `envTag` | string | `lab` | Environment tag value |

---

## Post-Deployment Steps

After infrastructure deployment, the following manual configuration is required:

### 1. Access VMs via Bastion
- Azure Portal → search for `{baseName}-bastion` → Connect to VM
- Use the admin credentials specified during deployment

### 1b. Connect via P2S VPN (Deploying Machine)
The VPN Gateway takes **25–45 minutes** to provision after deployment starts.
1. **Download VPN client config**: Portal → `{baseName}-vpngw` → Point-to-site configuration → Download VPN client
2. **Client cert**: Already installed in `CurrentUser\My` during deployment (auto-generated)
3. **Root cert**: Added to `CurrentUser\Trusted Root Certification Authorities` automatically
4. **Connect**: Extract the downloaded ZIP, run the VPN client configuration, then connect via Windows VPN settings
5. **VPN address**: Your workstation will receive a `172.16.0.x` IP with full access to the `10.0.0.0/16` lab network
6. **Certificates stored locally**: `certs/P2SRootCert.cer` and `certs/P2SClientCert.pfx` (PFX password = admin password from Key Vault)

### 1c. Connect via P2S VPN (Secondary Machine)
To connect from a workstation that was **not** used to run `deploy.ps1`, use the helper script:

1. **Copy the `certs/` folder** from the original deployment machine to the secondary machine
2. **Run the helper script**:
   ```powershell
   .\Install-VpnCerts.ps1 -BaseName azlab
   ```
3. The script will:
   - Import the root CA into `CurrentUser\Trusted Root Certification Authorities`
   - Import the client PFX into `CurrentUser\My` (prompts for the PFX password)
   - Download the VPN client configuration from Azure (requires Az CLI)
   - Extract and optionally open the VPN client installer folder
4. **PFX password**: This is the admin password from Key Vault. Retrieve it with:
   ```bash
   az keyvault secret show --vault-name {baseName}-kv --name vm-admin-password --query value -o tsv
   ```
5. **Without Az CLI**: Use `-SkipVpnClientDownload` and download the VPN client manually from the Azure Portal

> **Tip:** You can connect multiple machines — just copy the `certs/` folder and run `Install-VpnCerts.ps1` on each one.

### 2. Active Directory (Automated)
AD DS is automatically configured during Tier 1 deployment:
- **DC01** promoted as the first domain controller in a new forest
- **DC02** promoted as a replica domain controller
- **VNet DNS** set to DC IPs (10.0.1.4, 10.0.1.5) at deployment time
- **OUs**: Lab Accounts > Service Accounts, Lab Groups, Lab Servers > SQL Servers + App Servers
- **Security Groups**: GRP-DomainAdmins-Lab, GRP-SQLAdmins, GRP-AppAdmins, GRP-ServerAdmins, GRP-DomainJoin
- **Service Accounts**: svc-domjoin, svc-appadmin, svc-sqlsvc, svc-sqlagent, svc-appnaa
- **gMSA**: gmsa-sqlsvc (for SQL Server, retrieve principals: GRP-SQLAdmins)
- **Domain-join delegation**: svc-domjoin has CreateChild + WriteProperty on CN=Computers

> **Note:** After DC promotion, VMs may need a restart to pick up the custom DNS settings. DCs reboot automatically after promotion.

### 3. Domain-Join Remaining Servers
After AD is operational, domain-join SQL and application VMs using the `svc-domjoin` account.

### 4. SQL Server Installation
1. Install SQL Server (Enterprise or Developer edition) on all 5 SQL VMs
2. SQL VMs have **2 × 128GB Premium SSD data disks** pre-attached:
   - LUN 0: SQL Data files (drive D:)
   - LUN 1: SQL Log files (drive E:)
3. Format and mount data disks before SQL installation

### 5. WSFC + AOAG Configuration (Site 2)
1. Enable the **Failover Clustering** feature on both AOAG SQL nodes
2. Create a **Windows Server Failover Cluster** with both Site 2 SQL VMs
3. Configure **Cloud Witness** quorum using the deployed storage account:
   ```bash
   az storage account show --name <storage-account-name> --resource-group {base}-rg-identity --query name
   az storage account keys list --name <storage-account-name> --resource-group {base}-rg-identity --query [0].value
   ```
4. Enable **AlwaysOn Availability Groups** in SQL Server Configuration Manager
5. Create the Availability Group and configure the **AG Listener**:
   - Listener Name: `LISTENER-C`
   - IP Address: `10.0.40.10` (ILB frontend)
   - Probe Port: `59999`
   - SQL Port: `1433`
6. On each AOAG SQL node, configure the ILB probe port:
   ```powershell
   # Run on each SQL AOAG node
   $ClusterNetworkName = "Cluster Network 1"
   $IPResourceName = "LISTENER-C_10.0.40.10"
   $ListenerILBIP = "10.0.40.10"
   $ListenerProbePort = 59999

   Get-ClusterResource $IPResourceName |
     Set-ClusterParameter -Multiple @{
       Address = $ListenerILBIP
       ProbePort = $ListenerProbePort
       SubnetMask = "255.255.255.255"
       Network = $ClusterNetworkName
       EnableDhcp = 0
     }
   ```

### 6. Application Workload Installation
1. **Install CAS** on `{base}-cas` using SQL on `{base}-sqcs`
2. **Install Primary A** on `{base}-prma` using SQL on `{base}-sqpa` (same site as CAS)
3. **Install Primary B** on `{base}-prmb` using SQL on `{base}-sqpb` (remote Site 1)
4. **Install Primary C** on `{base}-prmc` using AOAG listener `LISTENER-C` on the Site 2 SQL cluster

> **Important:** When installing child primaries below a CAS, use the **CD.Latest** source media from the CAS site to ensure version compatibility. See [Microsoft docs](https://learn.microsoft.com/mem/configmgr/core/servers/deploy/install/setup-wizard-central-primary).

---

## Resource Groups

| Resource Group | Contents |
|---------------|----------|
| `{base}-rg-network` | VNet, NSGs, Azure Bastion, VPN Gateway, Public IPs |
| `{base}-rg-identity` | DC01, DC02, Key Vault, Cloud Witness Storage Account |
| `{base}-rg-main` | SQL-CAS, SQL-PrimA, CAS, PrimaryA |
| `{base}-rg-site1` | SQL-PrimB, PrimaryB |
| `{base}-rg-site2` | SQL-PrimC01, SQL-PrimC02, Availability Set, ILB, PrimaryC |

---

## Cleanup

Remove the entire lab using the deploy script (recommended):

```powershell
.\deploy.ps1 -BaseName azlab -Destroy
```

This will find all resource groups matching `{baseName}-rg-*`, confirm deletion, and delete them asynchronously.

Alternatively, delete resource groups manually:

```bash
# Delete all lab resource groups (irreversible!)
az group delete --name azlab-rg-network --yes --no-wait
az group delete --name azlab-rg-identity --yes --no-wait
az group delete --name azlab-rg-main --yes --no-wait
az group delete --name azlab-rg-site1 --yes --no-wait
az group delete --name azlab-rg-site2 --yes --no-wait
```

Or find them by tag:
```bash
az group list --tag env=lab --query "[].name" -o tsv | ForEach-Object { az group delete --name $_ --yes --no-wait }
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Quota exceeded** | Request quota increase: Portal → Subscriptions → Usage + quotas |
| **Deployment timeout** | Azure Bastion can take 10-15 minutes. Increase timeout or retry. |
| **Name conflict** | Storage account names are globally unique. Change `baseName` or the name will auto-resolve via `uniqueString()`. |
| **Bicep compilation error** | Run `az bicep build --file main.bicep` to see detailed errors |
| **Can't connect via Bastion** | Ensure NSG on target subnet allows inbound from `AzureBastionSubnet` on port 3389 (configured by default) |
| **AOAG Listener not responding** | Verify ILB probe port (59999) is open, floating IP is enabled, and cluster IP resource is configured |
| **VPN Gateway still provisioning** | VPN Gateways take 25–45 minutes. Check status: Portal → `{base}-vpngw` → Overview |
| **VPN client can't connect** | Verify client cert is in `CurrentUser\My` and root cert is in `CurrentUser\Trusted Root`. Re-download VPN client config. |
| **VPN connected but can't reach VMs** | Ensure VPN client address pool (`172.16.0.0/24`) doesn't overlap with your local network. Check NSG rules allow traffic. |
| **Key Vault access denied** | Ensure your Entra ID user/group was assigned during deployment, or add manually: Portal → Key Vault → Access control (IAM) |
| **AD DS promotion timeout** | Check `C:\WindowsTemp\PromoteDC1.log` or `ReplicaDC.log` on the DC VM |
| **AD configuration failure** | Check `C:\WindowsTemp\ConfigureAD.log` on DC01. RunCommand has 900s timeout. |
| **Domain not reachable from DC02** | Verify DC01 promotion completed, DNS resolves the domain name |
| **VM not domain-joined** | Ensure VMs have restarted after VNet DNS was set to DC IPs |

---

## References

- [Application Installation (MECM CAS/Primary)](https://learn.microsoft.com/mem/configmgr/core/servers/deploy/install/setup-wizard-central-primary)
- [Azure ILB for AG Listener](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/availability-group-load-balancer-portal-configure)
- [Cloud Witness for WSFC Quorum](https://learn.microsoft.com/windows-server/failover-clustering/deploy-cloud-witness)
- [Azure Bastion Documentation](https://learn.microsoft.com/azure/bastion/bastion-overview)
- [Azure P2S VPN with Certificate Auth](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-howto-point-to-site-resource-manager-portal)
- [Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)

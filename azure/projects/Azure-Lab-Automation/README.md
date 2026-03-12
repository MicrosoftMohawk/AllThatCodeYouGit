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
│  │   Azure Bastion     │  │   EntraConnect*     MgmtVM*               │ │
│  └─────────────────────┘  └────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─────────────────────┐  ┌────────────────────────────────────────────┐ │
│  │ GatewaySubnet       │  │ snet-pe (10.0.250.0/24)                   │ │
│  │ 10.0.255.0/27       │  │   Key Vault PE    (+ future PEs)          │ │
│  │   VPN Gateway       │  │                                            │ │
│  └─────────────────────┘  └────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │ P2S VPN Client Pool: 172.16.0.0/24                                 │ │
│  │   IKEv2 + SSTP — Certificate Auth  |  Self-signed root + client    │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
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

> **\*** *EntraConnect is deployed only when `enableEntraIntegration=true` and `entraConnectPlacement='dedicated'` (otherwise Entra Connect installs on DC02). MgmtVM is deployed separately via `deploy-mgmt.ps1` after the main lab deployment completes.*

### VM Inventory

The lab deploys up to **11 VMs** (or fewer with `colocateSql`), plus up to **2 additional VMs** when Entra ID integration is enabled.
All MCM and SQL VM names are **customizable** at deploy time via an interactive naming prompt or Bicep parameters.

#### Default Layout — Separate SQL (11 VMs)

| Default Name | Role | Size | Subnet | Tier |
|--------------|------|------|--------|------|
| `{base}-dc01` | Domain Controller | Standard_D2s_v5 | snet-ad | 1 |
| `{base}-dc02` | Domain Controller | Standard_D2s_v5 | snet-ad | 1 |
| `{base}-sqcs` | SQL Server (CAS DB) | Standard_D4s_v5 | snet-main | 2 |
| `{base}-sqpa` | SQL Server (PrimA DB) | Standard_D4s_v5 | snet-main | 2 |
| `{base}-sqpb` | SQL Server (PrimB DB) | Standard_D4s_v5 | snet-site1 | 2 |
| `{base}-sqc1` | SQL AOAG Node 1 (PrimC) | Standard_D8s_v5 | snet-site2 | 2 |
| `{base}-sqc2` | SQL AOAG Node 2 (PrimC) | Standard_D8s_v5 | snet-site2 | 2 |
| `{base}-cas` | MCM CAS Server | Standard_D4s_v5 | snet-main | 3 |
| `{base}-prma` | MCM Child Primary A | Standard_D4s_v5 | snet-main | 3 |
| `{base}-prmb` | MCM Child Primary B | Standard_D4s_v5 | snet-site1 | 3 |
| `{base}-prmc` | MCM Child Primary C | Standard_D4s_v5 | snet-site2 | 3 |

**Entra ID Integration VMs** (deployed when `enableEntraIntegration=true`):

| Default Name | Role | Size | Subnet | Tier |
|--------------|------|------|--------|------|
| `{base}-entr` | Entra Connect Sync* | Standard_D2s_v5 | snet-ad | 1 |
| `{base}-mgmt` | Management VM (Entra ID joined)** | Standard_D2s_v5 | snet-ad | Post |

\* Only deployed when `entraConnectPlacement='dedicated'`. Otherwise Entra Connect installs on DC02.

\*\* Deployed separately via `deploy-mgmt.ps1` after the main lab is running.

#### Colocated SQL Layout — SQL on MCM Servers (8 VMs)

When `-ColocateSql` is specified, SQL for CAS/PrimA/PrimB runs on the same VM as MCM. The MCM VMs are upsized to Standard_D8s_v5 and get data disks. Site 2 AOAG nodes are always separate.

| Default Name | Role | Size | Subnet | Tier |
|--------------|------|------|--------|------|
| `{base}-dc01` | Domain Controller | Standard_D2s_v5 | snet-ad | 1 |
| `{base}-dc02` | Domain Controller | Standard_D2s_v5 | snet-ad | 1 |
| `{base}-sqc1` | SQL AOAG Node 1 (PrimC) | Standard_D8s_v5 | snet-site2 | 2 |
| `{base}-sqc2` | SQL AOAG Node 2 (PrimC) | Standard_D8s_v5 | snet-site2 | 2 |
| `{base}-cas` | MCM CAS + SQL | Standard_D8s_v5 | snet-main | 3 |
| `{base}-prma` | MCM Primary A + SQL | Standard_D8s_v5 | snet-main | 3 |
| `{base}-prmb` | MCM Primary B + SQL | Standard_D8s_v5 | snet-site1 | 3 |
| `{base}-prmc` | MCM Child Primary C | Standard_D4s_v5 | snet-site2 | 3 |

> **Note:** All VM names (except DCs) can be overridden during deployment. The script displays a naming table and lets you customize each name.

---

## Prerequisites

| Requirement | Minimum Version | Check Command |
|-------------|-----------------|---------------|
| **Azure CLI** | 2.20.0+ | `az version` |
| **Bicep CLI** | (bundled with Az CLI) | `az bicep version` |
| **Azure Subscription** | — | `az account list -o table` |
| **RBAC** | Contributor on subscription | `az role assignment list --assignee <upn>` |

### Entra ID Integration Prerequisites (optional)

| Requirement | Notes |
|-------------|-------|
| **Entra ID tenant** | Any tenant — the code is not tied to a specific domain |
| **Azure AD Premium P2 license** | Required for Entra Connect Sync + Entra ID device login |
| **Global Administrator** | Needed during the Entra Connect wizard (post-deployment) |
| **Custom domain (recommended)** | Register your domain in Entra ID → Custom domain names |

### VM Quota Requirements

Ensure your subscription has sufficient vCPU quota in the target region:

#### Separate SQL mode (default — 11 VMs)

| VM Size | vCPUs each | Count | Total vCPUs |
|---------|-----------|-------|-------------|
| Standard_D2s_v5 | 2 | 2 (DCs) | 4 |
| Standard_D4s_v5 | 4 | 7 (3 standalone SQL + 4 MCM) | 28 |
| Standard_D8s_v5 | 8 | 2 (SQL AOAG) | 16 |
| **Total** | | **11** | **48 vCPUs** |

#### Colocated SQL mode (`-ColocateSql` — 8 VMs)

| VM Size | vCPUs each | Count | Total vCPUs |
|---------|-----------|-------|-------------|
| Standard_D2s_v5 | 2 | 2 (DCs) | 4 |
| Standard_D4s_v5 | 4 | 1 (PrimC — no SQL) | 4 |
| Standard_D8s_v5 | 8 | 5 (3 MCM+SQL colocated + 2 AOAG) | 40 |
| **Total** | | **8** | **48 vCPUs** |

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
| **1** | VNet, Subnets, NSGs, Azure Bastion, VPN Gateway (P2S), 2 DCs (static IPs), Cloud Witness Storage, Key Vault (private endpoint — no public access), **AD DS automation** (forest promotion, OUs, groups, service accounts, gMSA, replica DC) | Set up core networking, VPN, and AD only |
| **2** | + SQL VMs (with data disks), Availability Set, Internal Load Balancer. Standalone SQL VMs are skipped when `colocateSql` is true — only AOAG nodes are deployed. **Auto domain-join** SQL VMs (unless `joinDomain=false`). | Add SQL infrastructure |
| **3** | + MCM Application VMs (CAS + 3 child primaries). When `colocateSql` is true, MCM VMs are upsized and get data disks for SQL. **Auto domain-join** MCM VMs (unless `joinDomain=false`). | Full lab deployment |

Each tier is **cumulative** — Tier 3 includes everything from Tiers 1 and 2.

### Incremental Deployment

You can deploy Tier 1 first, then **incrementally** deploy Tier 2 or 3 later. The deployment script:

- **Auto-detects** existing Tier 1 infrastructure (resource groups, Key Vault, DCs)
- **Reuses** the admin password from Key Vault (prevents DC extension re-execution)
  - **Note:** Key Vault has no public endpoint — connect via VPN before running incremental deploys
- **Auto-detects** the AD domain name from DC01 (no need to re-enter it)
- **Skips** Key Vault RBAC prompts on incremental runs
- **Validates** the Azure CLI token before deployment (re-authenticates if expired)

```powershell
# Deploy Tier 1 first
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 1

# Later, add Tier 2 (domain name auto-detected from DC01)
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 2

# Or supply domain name explicitly to skip auto-detection
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 2 -DomainName azlab.local
```

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

# Incrementally add Tier 2 onto existing Tier 1
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 2

# Full lab with SQL colocated on MCM servers
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 3 -ColocateSql

# Deploy without domain-joining SQL/MCM VMs (workgroup servers)
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 3 -SkipDomainJoin

# Set VM timezone to Eastern (skips interactive prompt)
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 3 -TimeZone "Eastern Standard Time"

# Supply domain name to skip interactive prompt / auto-detection
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 2 -DomainName azlab.local

# Preview changes without deploying
.\deploy.ps1 -BaseName azlab -Location eastus -WhatIf

# Deploy with Entra ID hybrid identity integration
.\deploy.ps1 -BaseName azlab -Location eastus -DeploymentTier 3 -EnableEntraIntegration -EntraIdDomain contoso.com

# Deploy with Entra Connect on a dedicated VM (default: installs on DC02)
.\deploy.ps1 -BaseName azlab -Location eastus -EnableEntraIntegration -EntraIdDomain contoso.com -EntraConnectPlacement dedicated

# Deploy with independent AD domain (not a subdomain of Entra ID domain)
.\deploy.ps1 -BaseName azlab -Location eastus -EnableEntraIntegration -EntraIdDomain contoso.com -DomainStrategy independent -DomainName azlab.local

# Deploy to a specific subscription
.\deploy.ps1 -BaseName azlab -Location eastus -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

The script will:
- Check for Az CLI and Bicep CLI (installs Bicep if missing)
- Validate your Azure login **with token verification** (re-authenticates if expired)
- On **incremental deployments** (Tier 2+ on existing Tier 1):
  - Auto-detect existing infrastructure and reuse the admin password from Key Vault
  - Auto-detect the AD domain name from DC01 (or accept `-DomainName` parameter)
  - Skip Key Vault RBAC prompts
- Prompt for Key Vault Administrator (user UPN or Entra ID group) — first deployment only
- Compile and validate the Bicep template
- Auto-generate a secure admin password (stored in Key Vault) — first deployment only
- Prompt for the AD domain name — first deployment only (or accept `-DomainName`)
- Prompt for **VM timezone** — pick from Eastern/Central/Mountain/Pacific/UTC or enter a custom Windows timezone name (or accept `-TimeZone`)
- Display an **interactive naming table** for MCM/SQL servers — accept defaults or customize
- Offer the option to **colocate SQL on MCM servers** (or pass `-ColocateSql`)
- Prompt to **domain-join** SQL and MCM VMs (default: yes) — or pass `-SkipDomainJoin`
- Check the personal certificate store for existing VPN certs (by BaseName); generate new ones if not found
- Refresh the Azure CLI token before deploying
- Execute the deployment
- **Post-deployment**: Set VM timezone via RunCommand (`Set-TimeZone`) on all deployed VMs

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
├── deploy.ps1                             # PowerShell wrapper (prereqs, incremental detection, naming, deploy)
├── deploy-mgmt.ps1                        # Standalone: deploy management VM (Entra ID joined)
├── Install-VpnCerts.ps1                   # Helper: install VPN certs on secondary machines
├── Set-VpnDnsConfig.ps1                   # Helper: configure DNS NRPT rules for VPN private endpoint access
├── main.bicep                             # Subscription-scoped orchestrator (AD lab infrastructure)
├── mgmt.bicep                             # Resource-group-scoped: management VM + Entra ID join
├── bicepconfig.json                       # Bicep linter / analyzer config
├── MECM-Azure-Global-Lab.ps1              # Original PowerShell script (reference)
├── certs/                                 # Auto-generated VPN certificates
│   ├── P2SRootCert.cer                    # Root CA public key (re-exported every deploy)
│   ├── P2SClientCert.pfx                  # Client cert (re-exported with current admin password)
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
    │   ├── keyVault.bicep                 # Key Vault (password storage + RBAC assignment)
    │   └── keyVaultPrivateEndpoint.bicep   # Key Vault PE + private DNS zone
    └── identity/
        ├── promoteDC.bicep                # CSE: Promote DC01 as first DC (new forest)
        ├── configureAD.bicep              # RunCommand: OUs, groups, svc accounts, gMSA
        ├── replicaDC.bicep                # CSE: Promote DC02 as replica DC
        ├── domainJoin.bicep               # JsonADDomainExtension: join VM to AD domain
        ├── entraConnect.bicep             # RunCommand: Install Entra Connect Sync
        ├── entraIdJoin.bicep              # AADLoginForWindows extension (Entra ID join)
        ├── managementTools.bicep          # RunCommand: Install RSAT, Az module, Azure CLI
        ├── vmLoginRbac.bicep              # RBAC: Virtual Machine Administrator Login
        └── scripts/
            ├── Configure-AD.ps1           # AD configuration script (loaded inline)
            ├── Install-EntraConnect.ps1   # Download + silent install Entra Connect
            └── Install-ManagementTools.ps1 # RSAT, Az module, SqlServer, Azure CLI
```

---

## Parameters Reference

### deploy.ps1 Script Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-BaseName` | string | (required) | Base name prefix for all resources (max 10 chars) |
| `-Location` | string | (required) | Azure region |
| `-DeploymentTier` | int | `3` | 1 = Core/AD, 2 = +SQL, 3 = +MCM servers (full) |
| `-DomainName` | string | (auto) | AD domain name. Skips prompt on first run; auto-detected from DC01 on incremental runs |
| `-ColocateSql` | switch | `$false` | When set, SQL runs on MCM servers (no separate SQL VMs) |
| `-SkipDomainJoin` | switch | `$false` | When set, SQL and MCM VMs are NOT domain-joined (deployed as workgroup servers) |
| `-TimeZone` | string | (prompt) | Windows timezone for all VMs (e.g., `Eastern Standard Time`). If omitted, an interactive menu is shown. |
| `-SubscriptionId` | string | (current) | Target Azure subscription ID |
| `-WhatIf` | switch | `$false` | Preview deployment changes without applying |
| `-Destroy` | switch | `$false` | Delete all lab resource groups |
| `-EnableEntraIntegration` | switch | `$false` | Enable Entra ID hybrid identity (Entra Connect, management VM, Entra ID join) |
| `-EntraIdDomain` | string | (prompt) | Entra ID verified domain (e.g., `contoso.com`) |
| `-DomainStrategy` | string | `subdomain` | `subdomain` = AD domain is `ad.<EntraIdDomain>`, `independent` = AD domain configured separately |
| `-EntraConnectPlacement` | string | `dc02` | `dc02` = install Entra Connect on DC02, `dedicated` = deploy a separate Entra Connect VM |

### Bicep Template Parameters (main.bicep)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `baseName` | string | `azlab` | Base name prefix for all resources (max 10 chars) |
| `location` | string | `eastus` | Azure region |
| `deploymentTier` | int | `3` | 1 = Core/AD, 2 = +SQL, 3 = +MCM servers (full) |
| `colocateSql` | bool | `false` | When true, SQL runs on MCM servers (no separate SQL VMs for CAS/PrimA/PrimB) |
| `joinDomain` | bool | `true` | When true, SQL and MCM VMs are auto-joined to the AD domain using `svc-domjoin`. SQL VMs → OU=SQL Servers, MCM VMs → OU=App Servers |
| `adminUsername` | string | `labadmin` | Local admin username for all VMs |
| `adminPassword` | securestring | — | Local admin password (auto-generated by deploy.ps1) |
| `domainName` | string | — | AD domain name (prompted or auto-detected by deploy.ps1) |
| `sizeDC` | string | `Standard_D2s_v5` | VM size for Domain Controllers |
| `sizeApp` | string | `Standard_D4s_v5` | VM size for MCM servers (when SQL is separate) |
| `sizeAppColocated` | string | `Standard_D8s_v5` | VM size for MCM servers when SQL is colocated |
| `sizeSQL` | string | `Standard_D4s_v5` | VM size for standalone SQL VMs |
| `sizeSQLAoag` | string | `Standard_D8s_v5` | VM size for AOAG SQL VMs |
| **VM Naming** | | | |
| `vmNameSqlCas` | string | `{base}-sqcs` | SQL VM for CAS site (ignored when colocateSql=true) |
| `vmNameSqlPrimA` | string | `{base}-sqpa` | SQL VM for Primary A (ignored when colocateSql=true) |
| `vmNameSqlPrimB` | string | `{base}-sqpb` | SQL VM for Primary B (ignored when colocateSql=true) |
| `vmNameSqlAoag1` | string | `{base}-sqc1` | SQL AOAG Node 1 (Site 2) |
| `vmNameSqlAoag2` | string | `{base}-sqc2` | SQL AOAG Node 2 (Site 2) |
| `vmNameCas` | string | `{base}-cas` | MCM CAS server |
| `vmNamePrimA` | string | `{base}-prma` | MCM Child Primary A |
| `vmNamePrimB` | string | `{base}-prmb` | MCM Child Primary B |
| `vmNamePrimC` | string | `{base}-prmc` | MCM Child Primary C |
| **Networking** | | | |
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
| **Entra ID Integration** | | | |
| `enableEntraIntegration` | bool | `false` | Enable Entra ID hybrid identity features |
| `entraIdDomain` | string | `''` | Entra ID verified domain (e.g., `contoso.com`) |
| `domainStrategy` | string | `subdomain` | `subdomain` = AD domain is `ad.<entraIdDomain>`, `independent` = separate names |
| `entraConnectPlacement` | string | `dc02` | `dc02` = install on DC02, `dedicated` = separate VM |
| `vmNameMgmt` | string | `{base}-mgmt` | Management VM name (Entra ID joined) |
| `vmNameEntraConnect` | string | `{base}-entr` | Entra Connect VM name (when placement = dedicated) |
| `sizeManagement` | string | `Standard_D2s_v5` | VM size for Management VM and Entra Connect VM |

---

## Post-Deployment Steps

After infrastructure deployment, the following manual configuration is required:

### 1. Access VMs via Bastion
- Azure Portal → search for `{baseName}-bastion` → Connect to VM
- Use the admin credentials specified during deployment

### 1b. Connect via P2S VPN (Deploying Machine)
The VPN Gateway takes **25–45 minutes** to provision after deployment starts.
1. **Download VPN client config**: Portal → `{baseName}-vpngw` → Point-to-site configuration → Download VPN client
2. **Client cert**: Already installed in `CurrentUser\My` during deployment (looked up by BaseName or auto-generated)
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

### 1d. VPN DNS Configuration (Private Endpoints)

When connected to the P2S VPN, your workstation may still use its **local DNS** (e.g., your home router) instead of the Azure DCs. This causes private endpoint resolution to fail — resources like Key Vault return public IPs, and you get:

> _"Public network access is disabled and request is not from a trusted service nor via an approved private link"_

This happens because Windows routes DNS queries through the network adapter with the **lowest interface metric**, which is typically your local Ethernet/Wi-Fi — not the VPN adapter.

The `Set-VpnDnsConfig.ps1` script solves this by managing **NRPT (Name Resolution Policy Table)** rules that route Azure Private DNS zone queries through the lab's Domain Controllers. A scheduled task automatically adds/removes these rules on VPN connect/disconnect.

**Install (one-time, requires Admin PowerShell):**
```powershell
.\Set-VpnDnsConfig.ps1 -Action Install -BaseName tst10
```

This will:
- Add NRPT rules for Azure Private DNS zones (`*.vault.azure.net`, `*.blob.core.windows.net`, etc.) pointing to the lab DCs (`10.0.1.4`, `10.0.1.5`)
- Create a scheduled task that **automatically** adds the rules on VPN connect and removes them on disconnect
- Rules are scoped — only private endpoint DNS zones are redirected; all other DNS continues through your normal resolver

**Verify it's working:**
```powershell
# Resolve-DnsName respects NRPT rules (nslookup does NOT)
Resolve-DnsName {baseName}-kv-*.vault.azure.net
# Should return a 10.0.250.x address (private endpoint IP), not a public IP
```

**Uninstall:**
```powershell
.\Set-VpnDnsConfig.ps1 -Action Uninstall -BaseName tst10
```

**Custom DNS servers:** If your DCs use non-default IPs:
```powershell
.\Set-VpnDnsConfig.ps1 -Action Install -BaseName mylab -DnsServers 10.0.1.10,10.0.1.11
```

> **Note:** `nslookup` bypasses NRPT rules and always queries the adapter's DNS server directly. Use `Resolve-DnsName` to verify NRPT-based resolution. Applications (browsers, Az CLI, PowerShell modules) all use the NRPT path.

### 2. Active Directory (Automated)
AD DS is automatically configured during Tier 1 deployment:
- **DC01** promoted as the first domain controller in a new forest
- **DC02** promoted as a replica domain controller
- **VNet DNS** set to DC IPs (10.0.1.4, 10.0.1.5) at deployment time
- **OUs**: Lab Accounts > Service Accounts, Lab Accounts > Admins, Lab Groups, Lab Servers > SQL Servers + App Servers
- **Security Groups**: GRP-DomainAdmins-Lab, GRP-SQLAdmins, GRP-AppAdmins, GRP-ServerAdmins, GRP-DomainJoin
- **Service Accounts** (OU=Service Accounts): svc-domjoin, svc-appadmin, svc-sqlsvc, svc-sqlagent, svc-appnaa
- **Admin Accounts** (OU=Admins): lab-admin (delegated OU admin, member of GRP-ServerAdmins + GRP-SQLAdmins + GRP-AppAdmins + GRP-MCMAdmins), mcm-admin, sql-admin
- **gMSA**: gmsa-sqlsvc (for SQL Server, retrieve principals: GRP-SQLAdmins)
- **Domain-join delegation**: svc-domjoin has CreateChild + WriteProperty on CN=Computers
- **OU delegation**: lab-admin has GenericAll on Lab Servers, Lab Accounts, Lab Groups OUs
- **DNS Forwarder**: `168.63.129.16` (Azure-provided DNS) configured on both DCs so VMs can resolve public hostnames

> **Note:** After DC promotion, VMs may need a restart to pick up the custom DNS settings. DCs reboot automatically after promotion.

### 3. Domain Join (Automated by Default)
By default, all SQL and MCM VMs are **automatically domain-joined** during deployment using the `svc-domjoin` service account (created by the AD automation in Tier 1).

- **SQL VMs** are placed in `OU=SQL Servers,OU=Lab Servers,DC=...,DC=...`
- **MCM VMs** are placed in `OU=App Servers,OU=Lab Servers,DC=...,DC=...`
- The join uses the `JsonADDomainExtension` (Microsoft.Compute.JsonADDomainExtension)
- VMs reboot automatically after joining the domain
- The extension depends on AD configuration completing first (OUs and svc-domjoin must exist)

If you deployed with `-SkipDomainJoin` (or `joinDomain=false`), VMs remain in a workgroup. You can domain-join them manually later using the `svc-domjoin` account.

### 3a. Entra Connect Sync Setup (when `-EnableEntraIntegration`)

Entra Connect is **installed automatically** during deployment, but the configuration wizard requires interactive Global Admin authentication. Use **Custom installation** (not Express) to configure OU filtering.

#### Initial Configuration

1. **Connect** to the Entra Connect VM (or DC02, depending on `entraConnectPlacement`) via Bastion
2. **Launch** the Entra Connect wizard from the desktop shortcut
3. **Accept** the license terms, click Continue
4. **Click "Customize"** (not Express Settings) — this enables OU filtering
5. **Install prerequisites**: Click "Install" (no optional components needed for the lab)
6. **User Sign-in**: Select **"Password Hash Synchronization"**, click Next
7. **Connect to Azure AD**: Sign in with an Entra ID **Global Administrator** account
8. **Connect Directories**:
   - Forest: `<domainName>` → click "Add Directory"
   - Select "Create new AD account"
   - Enter Enterprise Admin credentials: `<domain>\labadmin` with the admin password from Key Vault
9. **Azure AD sign-in configuration**: Verify the UPN suffix is shown and configured, click Next
   - **Subdomain mode** (`domainStrategy=subdomain`): AD domain is `ad.<entraIdDomain>` — the Entra ID domain should show as a verified UPN suffix
   - **Independent mode** (`domainStrategy=independent`): The Entra ID domain was added as an alternate UPN suffix in AD — verify it shows as "Verified"
10. **Domain and OU filtering**: Select **"Sync selected domains and OUs"**
    - Uncheck all OUs, then check **only**:
      - ☑ `Lab Accounts`
      - ☑ `Lab Groups`
      - ☑ `Lab Servers`
11. **Uniquely identifying users**: Keep defaults (users are represented once, match by mail attribute), click Next
12. **Filter users and devices**: Keep "Synchronize all users and devices", click Next
13. **Optional features**: "Password hash synchronization" should already be checked
    - No additional features are needed for the lab
    - Optional: Check "Password writeback" if you want Entra ID SSPR to write back to AD
14. **Click "Install"** to start configuration and initial sync
15. **Wait** for synchronization to complete (typically 2–5 minutes)

> **Verify sync**: Azure Portal → Entra ID → Users — you should see the synced AD accounts (lab-admin, mcm-admin, sql-admin, service accounts).

#### Optional: Hybrid Entra ID Join (after initial sync)

To allow domain-joined lab VMs to also register in Entra ID (hybrid join):

1. Re-open the Entra Connect wizard → **Configure** → **Device options**
2. Select **"Configure Hybrid Microsoft Entra ID join"**
3. Authenticate with Global Administrator credentials
4. Check **"Windows 10 or later domain-joined devices"**
5. Select your forest → click **Configure** to set the SCP (Service Connection Point)
6. Enter Enterprise Admin credentials when prompted
7. Click **Configure** to apply

After configuration, domain-joined VMs will automatically register in Entra ID on their next reboot or policy refresh.

#### Artifacts Storage (Azure Files)

Deploy the `ArtifactsStorage` project to create a private Azure Files share for ISOs, installers, and configuration files. Two authentication modes are available — choose based on your needs:

**Option 1 — AD DS Registration (default, recommended for labs):**
```powershell
cd ../ArtifactsStorage
.\deploy.ps1 -NamePrefix artifacts -Location <region> -LabBaseName <base>
```
- Registers the storage account as a computer object in AD (runs on DC01)
- **All domain-joined VMs** (including DCs) can mount via `net use` — any domain user works
- Management VM (Entra ID joined) accesses via `az storage file --auth-mode login` (OAuth)

**Option 2 — Entra ID Kerberos (`-EnableEntraKerberos`):**
```powershell
.\deploy.ps1 -NamePrefix artifacts -Location <region> -LabBaseName <base> -EnableEntraKerberos
```
- No AD computer account created
- **Requires**: PHS enabled in Entra Connect + Hybrid Entra ID Join on client VMs
- SMB `net use` only works from Hybrid Entra ID joined VMs, logged in as a **synced user** (e.g., `lab-admin`)
- **DCs cannot mount** via SMB (DCs cannot be hybrid joined) — use `az storage file --auth-mode login` instead
- The built-in `labadmin` account (in `CN=Users`) is never synced and cannot mount via Kerberos
- Management VM (Entra ID joined) accesses via `az storage file --auth-mode login` (OAuth)

**Access summary by VM type:**

| VM Type | AD DS mode (`net use`) | Entra Kerberos mode (`net use`) | OAuth (`az storage file --auth-mode login`) |
|---------|----------------------|-------------------------------|-------------------------------------------|
| Domain-joined VMs (SQL, MCM) | **Yes** — any domain user | **Only if** Hybrid Entra ID joined + synced user | Yes (with Az CLI + RBAC) |
| Domain Controllers | **Yes** — any domain user | **No** — DCs cannot be hybrid joined | Yes (with Az CLI + RBAC) |
| Management VM (Entra joined) | **No** — not domain-joined | **Yes** — has PRT, synced user | **Yes** — recommended path |
| VPN workstation | **No** — not domain-joined | **No** — not domain/hybrid joined | **Yes** — recommended path |

> **Recommendation**: Use AD DS registration for labs. It works with every domain-joined VM (including DCs) with zero extra config. The management VM and VPN workstations use `az storage file --auth-mode login` regardless of which mode is chosen.

### 3b. Management VM (separate deployment)

The Management VM (`{base}-mgmt`) is deployed **separately** via `deploy-mgmt.ps1` after the main lab deployment completes. This ensures the AD infrastructure (DCs, DNS forwarders) is fully operational before the Entra ID join is attempted.

```powershell
# Deploy the management VM after the main lab is running
.\deploy-mgmt.ps1 -BaseName <base> -Location <region>
```

The script automatically retrieves the admin password from Key Vault. The VM is **pure Entra ID joined** (not AD domain-joined) via the `AADLoginForWindows` extension and comes pre-installed with:
- **RSAT**: AD Users & Computers, DNS Manager, Group Policy Management
- **Az PowerShell module**
- **SqlServer PowerShell module**
- **Azure CLI**

**Login**: Connect via Bastion using your **Entra ID credentials** (the deployer is assigned the `Virtual Machine Administrator Login` role automatically).

**Managing AD from a non-domain-joined VM**: The `lab-admin` account is created during AD configuration with delegated full control over the Lab OUs (`Lab Servers`, `Lab Accounts`, `Lab Groups`). It is **not** a Domain Admin — it has only the permissions needed to manage lab infrastructure. To use RSAT tools:

```powershell
# Launch AD Users & Computers with AD credentials
runas /netonly /user:yourdomain.lab\lab-admin "mmc dsa.msc"
```

Alternatively, RSAT tools will prompt for credentials when you connect to a DC. The VNet DNS already points to the DCs (`10.0.1.4`, `10.0.1.5`), so AD is fully resolvable from the management VM.

### 4. VM Timezone (Automated)
During deployment, the script prompts for a timezone (or accepts `-TimeZone`). After the Bicep deployment completes, the timezone is applied via `az vm run-command invoke` running `Set-TimeZone` on every deployed VM.

- **Why not ARM?** Azure treats `windowsConfiguration.timeZone` as immutable on existing VMs — it can only be set at initial creation. Using RunCommand works on both new and existing VMs, making incremental deployments safe.
- **Default**: If you press Enter at the prompt, **Eastern Standard Time** is selected.
- **UTC VMs**: If you select UTC, the RunCommand step is skipped (Windows Server defaults to UTC).

Available presets:
| Choice | Windows Timezone ID |
|--------|--------------------|
| 1 (default) | `Eastern Standard Time` |
| 2 | `Central Standard Time` |
| 3 | `Mountain Standard Time` |
| 4 | `Pacific Standard Time` |
| 5 | `UTC` |
| 6 | Custom (any valid Windows timezone name) |

### 5. SQL Server Installation
1. Install SQL Server (Enterprise or Developer edition) on SQL VMs
   - **Separate SQL mode**: Install on all dedicated SQL VMs
   - **Colocated SQL mode**: Install on the MCM VMs (CAS, PrimA, PrimB) and AOAG nodes
2. SQL VMs have **2 × 128GB Premium SSD data disks** pre-attached:
   - LUN 0: SQL Data files (drive D:)
   - LUN 1: SQL Log files (drive E:)
3. Format and mount data disks before SQL installation

### 6. WSFC + AOAG Configuration (Site 2)
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

### 7. MCM Application Workload Installation
1. **Install CAS** on the CAS VM using its SQL instance (colocated or dedicated)
2. **Install Primary A** on the PrimA VM using its SQL instance (same site as CAS)
3. **Install Primary B** on the PrimB VM using its SQL instance (remote Site 1)
4. **Install Primary C** on the PrimC VM using AOAG listener `LISTENER-C` on the Site 2 SQL cluster

> **Note:** When colocated, SQL is on the same VM as the MCM role — update SQL instance names accordingly during MCM setup.

> **Important:** When installing child primaries below a CAS, use the **CD.Latest** source media from the CAS site to ensure version compatibility. See [Microsoft docs](https://learn.microsoft.com/mem/configmgr/core/servers/deploy/install/setup-wizard-central-primary).

---

## Resource Groups

| Resource Group | Contents |
|---------------|----------|
| `{base}-rg-network` | VNet, NSGs, Azure Bastion, VPN Gateway, Public IPs |
| `{base}-rg-identity` | DC01, DC02, Key Vault, Cloud Witness Storage Account |
| `{base}-rg-main` | SQL-CAS, SQL-PrimA, CAS, PrimaryA (SQL VMs omitted when colocated) |
| `{base}-rg-site1` | SQL-PrimB, PrimaryB (SQL VM omitted when colocated) |
| `{base}-rg-site2` | SQL AOAG Node 1, SQL AOAG Node 2, Availability Set, ILB, PrimaryC |

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
| **Token expired / invalid_grant** | The script now validates the token before deployment. If you still see this, run `az logout` then `az login` manually. |
| **Incremental deploy re-runs DC extensions** | Ensure the script detects existing Tier 1 and reuses the admin password from Key Vault. Pass `-DomainName` if auto-detection fails. |
| **GatewaySubnet deletion error** | The VNet template includes GatewaySubnet inline to prevent this. If upgrading from an older version, redeploy once to reconcile. |
| **Name conflict** | Storage account names are globally unique. Change `baseName` or the name will auto-resolve via `uniqueString()`. |
| **Bicep compilation error** | Run `az bicep build --file main.bicep` to see detailed errors |
| **Can't connect via Bastion** | Ensure NSG on target subnet allows inbound from `AzureBastionSubnet` on port 3389 (configured by default) |
| **AOAG Listener not responding** | Verify ILB probe port (59999) is open, floating IP is enabled, and cluster IP resource is configured |
| **VPN Gateway still provisioning** | VPN Gateways take 25–45 minutes. Check status: Portal → `{base}-vpngw` → Overview |
| **VPN client can't connect** | Verify client cert is in `CurrentUser\My` and root cert is in `CurrentUser\Trusted Root`. Re-download VPN client config. |
| **VPN connected but can't reach VMs** | Ensure VPN client address pool (`172.16.0.0/24`) doesn't overlap with your local network. Check NSG rules allow traffic. |
| **VPN connected but private endpoints fail** | Your local DNS resolves to public IPs. Run `Set-VpnDnsConfig.ps1 -Action Install -BaseName {base}` in Admin PowerShell. Verify with `Resolve-DnsName` (not `nslookup`). See [1d. VPN DNS Configuration](#1d-vpn-dns-configuration-private-endpoints). |
| **Key Vault access denied** | Ensure your Entra ID user/group was assigned during deployment, or add manually: Portal → Key Vault → Access control (IAM) |
| **AD DS promotion timeout** | Check `C:\WindowsTemp\PromoteDC1.log` or `ReplicaDC.log` on the DC VM |
| **AD configuration failure** | Check `C:\WindowsTemp\ConfigureAD.log` on DC01. RunCommand has 900s timeout. |
| **VMs can't resolve public DNS** | Ensure the DNS forwarder (`168.63.129.16`) is configured on DCs. The Configure-AD script adds it automatically. Verify: `Get-DnsServerForwarder` on DC01. |
| **VM timezone not set** | Timezone is applied post-deployment via RunCommand. Re-run manually: `Set-TimeZone -Id 'Eastern Standard Time'` inside the VM. |
| **Timezone change fails on redeploy** | ARM does not allow changing `windowsConfiguration.timeZone` on existing VMs. The deploy script uses RunCommand instead, which is safe for incremental deployments. |
| **Domain not reachable from DC02** | Verify DC01 promotion completed, DNS resolves the domain name |
| **VM not domain-joined** | Ensure VMs have restarted after VNet DNS was set to DC IPs |
| **Domain join extension failed** | Check the VM's extensions blade in the Azure Portal. The `JoinDomain` extension logs errors there. Verify DC01/DC02 are running, DNS resolves the domain, and `svc-domjoin` account exists in AD. |
| **Entra Connect wizard fails** | Ensure the VM has internet access (NAT Gateway on snet-ad). Verify Global Admin credentials and that the Entra ID domain is verified. Check `C:\ProgramData\AADConnect\*.log`. |
| **Entra ID join (AADLoginForWindows) failed** | Check the extension status in the Portal. VM must have internet access to reach `login.microsoftonline.com`. Ensure an AD P2 license is available. |
| **Can't login to Management VM with Entra ID** | Verify the `Virtual Machine Administrator Login` RBAC role is assigned. Connect via Bastion and use `AzureAD\user@domain.com` format. |
| **Entra Connect install failed** | Check RunCommand output in the Portal. The MSI download requires TLS 1.2 and internet access. Review `C:\WindowsTemp\EntraConnect-Install.log` on the target VM. |
| **Password breaks az CLI on Windows** | The admin password charset avoids `&`, `%`, `^` which break cmd.exe argument parsing. If you see truncated parameter errors, regenerate with a fresh deploy. |

---

## References

- [Application Installation (MECM CAS/Primary)](https://learn.microsoft.com/mem/configmgr/core/servers/deploy/install/setup-wizard-central-primary)
- [Azure ILB for AG Listener](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/availability-group-load-balancer-portal-configure)
- [Cloud Witness for WSFC Quorum](https://learn.microsoft.com/windows-server/failover-clustering/deploy-cloud-witness)
- [Azure Bastion Documentation](https://learn.microsoft.com/azure/bastion/bastion-overview)
- [Azure P2S VPN with Certificate Auth](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-howto-point-to-site-resource-manager-portal)
- [Microsoft Entra Connect Sync](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-install-express)
- [AADLoginForWindows VM Extension](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows)
- [Azure Files Entra ID Kerberos Authentication](https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable)
- [Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)

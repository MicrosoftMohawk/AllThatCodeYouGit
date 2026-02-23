# Connect-AzureVMBastion.ps1 💻

This PowerShell script connects to an **Azure Virtual Machine (VM)** using **Azure Bastion’s Native RDP Client Support** via a **local tunnel**.  
It automatically validates prerequisites, creates a Bastion tunnel, and launches the **Windows Remote Desktop Client (mstsc)**.

---

## 🧠 Overview

Azure Bastion allows secure, browser-based or native client-based connectivity to VMs without exposing public IPs.  
This script simplifies connecting to your VM via **Azure Bastion** using **RDP**, the **Azure CLI**, and a **local tunnel (port 55000)**.
When run **without parameters**, the script enters **interactive mode** — it queries your Azure environment and presents numbered selection menus to discover and choose subscriptions, Bastion hosts, resource groups, and VMs. When parameters are provided on the command line, those prompts are skipped for **full backward compatibility**.

---

## ⚙️ Requirements

Before using the script, ensure you have:
- **PowerShell 5.1+** or **PowerShell 7+**
- **Azure CLI Extnsion: az bastion**
- **Azure CLI** (az) installed → [Install Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- An existing **Azure Bastion** resource with **Native Client Support** enabled:
  ```bash
  az network bastion update --name <your-bastion> --resource-group <your-rg> --enable-tunneling true
  ```
- Appropriate **RBAC permissions** (read access to VM and Bastion resources)

---

## 📦 Parameters

| Parameter | Required | Description |
|------------|-----------|-------------|
| **VMName** | ❌ | Name of the target Azure VM. If omitted, the script lists available VMs and prompts for selection |
| **ResourceGroupName** | ❌ | Name of the resource group containing the VM. If omitted, the script lists available resource groups and prompts for selection |
| **BastionName** | ❌ | Name of the Azure Bastion resource. If omitted, the script lists available Bastion hosts across the subscription and prompts for selection |
| **BastionResourceGroupName** | ❌ | Resource group of the Bastion host, when it differs from the VM resource group. Auto-populated in interactive mode. Defaults to `ResourceGroupName` if omitted |
| **SubscriptionId** | ❌ | Azure Subscription ID. If omitted, the script offers an interactive subscription picker |
| **UseAllMonitors** | ❌ | Enables multi-monitor mode when launching RDP (defaults to single monitor) |

---

## 🚀 Examples

**Fully interactive mode (no parameters):**
```powershell
.\Connect-AzureVMBastion.ps1
# Prompts for subscription, Bastion host, resource group, and VM selection.
```

**Basic connection (all parameters specified — no prompts):**
```powershell
.\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion"
```

**Bastion in a different resource group than the VM:**
```powershell
.\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -BastionResourceGroupName "myNetworkRG"
```

**Partial interactive — only prompt for missing resources:**
```powershell
.\Connect-AzureVMBastion.ps1 -ResourceGroupName "myRG"
# Prompts for subscription, Bastion, and VM only.
```

**Specify subscription:**
```powershell
.\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

**Enable all monitors:**
```powershell
.\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion" -UseAllMonitors
```

---

## 🔍 What the Script Does

1. **Verifies Azure CLI installation**
2. **Checks login status** to Azure and prompts login if necessary
3. **Interactive subscription selection** — lists available subscriptions and lets you choose (skipped if `-SubscriptionId` is provided)
4. **Interactive Bastion host discovery** — queries all Bastion hosts across the subscription and lets you choose (skipped if `-BastionName` is provided; auto-selects if only one exists)
5. **Interactive resource group selection** — lists resource groups and lets you choose the VM’s RG (skipped if `-ResourceGroupName` is provided)
6. **Interactive VM selection** — lists VMs in the selected resource group and lets you choose (skipped if `-VMName` is provided)
7. **Retrieves VM and Bastion Resource IDs**
8. **Validates tunneling support** on the Bastion host
9. **Starts Azure Bastion tunnel** on local port 55000
10. **Creates a temporary RDP configuration file**
11. **Launches mstsc.exe** (Remote Desktop Connection)
12. **Cleans up temporary tunnel/RDP files** after session ends

---

## 🧩 Troubleshooting

If the tunnel fails or closes unexpectedly:
- Verify Bastion’s **Native Client support** is enabled.
- Confirm **Azure CLI** is authenticated (`az login`).
- Check for **port conflicts** with local port 55000.
- Ensure Bastion and VM resources belong to the same **virtual network or peered networks**.

---

## 🧰 Notes

- The Bastion tunnel remains active in a separate PowerShell window until manually closed.  
- On exit, temporary `.rdp` and `.ps1` helper files are safely removed.  
- Script works best on **Windows hosts with mstsc.exe** (native RDP client).

---

## Change Log

| Date | Version | Changes |
|------|---------|---------|  
| 2025-12-18 | 1.0 | Initial custom initiative deployment |
| 2026-01-02 | 1.0 | Code updates |
| 2026-01-03 | 1.0 | Code enhancements |
| 2026-02-23 | 1.1 | Added interactive resource discovery (subscription, Bastion, resource group, VM selection). Added BastionResourceGroupName parameter for cross-RG Bastion support. All parameters now optional with backward compatibility |

---

## 📜 License

This script is licensed under the [MIT License](LICENSE).

---

## 🤖 Author & Source

Created by "Bryan Heusmann" to simplify **Azure VM Remote Desktop connectivity** through **Azure Bastion Native Client**.  
Feel free to fork, modify, and contribute improvements via pull requests.

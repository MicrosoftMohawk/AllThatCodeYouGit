# Connect-AzureVMBastion.ps1 💻

This PowerShell script connects to an **Azure Virtual Machine (VM)** using **Azure Bastion’s Native RDP Client Support** via a **local tunnel**.  
It automatically validates prerequisites, creates a Bastion tunnel, and launches the **Windows Remote Desktop Client (mstsc)**.

---

## 🧠 Overview

Azure Bastion allows secure, browser-based or native client-based connectivity to VMs without exposing public IPs.  
This script simplifies connecting to your VM via **Azure Bastion** using **RDP**, the **Azure CLI**, and a **local tunnel (port 55000)**.

---

## ⚙️ Requirements

Before using the script, ensure you have:
- **PowerShell 5.1+** or **PowerShell 7+**
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
| **VMName** | ✅ | Name of the target Azure VM |
| **ResourceGroupName** | ✅ | Name of the resource group containing the VM |
| **BastionName** | ✅ | Name of the Azure Bastion resource used for connection |
| **SubscriptionId** | ❌ | Optional Azure Subscription ID. If omitted, the current active subscription is used |
| **UseAllMonitors** | ❌ | Enables multi-monitor mode when launching RDP (defaults to single monitor) |

---

## 🚀 Examples

**Basic connection:**
```powershell
.\Connect-AzureVMBastion.ps1 -VMName "myVM" -ResourceGroupName "myRG" -BastionName "myBastion"
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
3. **Optionally switches subscription**
4. **Retrieves VM and Bastion Resource IDs**
5. **Validates tunneling support** on the Bastion host
6. **Starts Azure Bastion tunnel** on local port 55000
7. **Creates a temporary RDP configuration file**
8. **Launches mstsc.exe** (Remote Desktop Connection)
9. **Cleans up temporary tunnel/RDP files** after session ends

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

## 📜 License

This script is licensed under the [MIT License](LICENSE).

---

## 🤖 Author & Source

Created by "Bryan Heusmann" to simplify **Azure VM Remote Desktop connectivity** through **Azure Bastion Native Client**.  
Feel free to fork, modify, and contribute improvements via pull requests.

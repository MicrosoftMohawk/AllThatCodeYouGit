# Azure Execution and Operations Management

## Synopsis

This directory contains PowerShell scripts designed for Azure resource execution and operational management. The scripts provide interactive, user-friendly interfaces for managing Azure infrastructure across both Azure Commercial (Public Cloud) and Azure Government environments. These tools enable system administrators and cloud operators to efficiently manage virtual machine lifecycle operations, cloud governance, security policies, and remote access capabilities.

## Overview

The scripts in this collection support multi-cloud environments with intelligent context switching, subscription management, and resource selection. All scripts include comprehensive error handling, logging capabilities, and user confirmation workflows to ensure safe and reliable Azure operations.

---

## Scripts

### Manage-AzureVMPowerState.ps1

**Description:**  
Interactive script for managing Azure virtual machine power states across Commercial and Government cloud environments.

**Purpose:**
- Power on Azure virtual machines
- Power off Azure virtual machines
- Restart Azure virtual machines
- Monitor VM power state status

**Key Features:**
- Automatic detection of current Azure login context
- Smart environment selection with option to continue or switch cloud environments
- Interactive subscription selection
- Resource group filtering
- Virtual machine selection with status display
- Support for both Azure Commercial and Azure Government
- Non-blocking asynchronous operations

**Requirements:**
- PowerShell 5.1 or higher
- `Az.Accounts` module
- `Az.Compute` module

**Installation:**
```powershell
Install-Module -Name Az.Accounts -Force
Install-Module -Name Az.Compute -Force
```

**Usage:**
```powershell
.\Manage-AzureVMPowerState.ps1
```

**Workflow:**
1. Checks current Azure login status
2. Prompts for cloud environment selection (if not logged in or to switch)
3. Authenticates to selected Azure environment
4. Guides through subscription selection
5. Guides through resource group selection
6. Guides through virtual machine selection
7. Displays current VM power state
8. Prompts for power action (On/Off/Restart)
9. Executes requested action

**Output:**
- Color-coded console output for status and actions
- Real-time operation feedback
- Current VM status information

---

## Folder Structure

### Possible Sub-Folders (for Future Expansion)

#### `/modules`
Contains reusable PowerShell modules for common Azure operations.

**Expected modules:**
- `AzureAuthentication.psm1` - Authentication and context management functions
- `AzureVMManagement.psm1` - Virtual machine operations
- `AzureResourceManagement.psm1` - General resource management utilities
- `AzureLogging.psm1` - Logging and audit functions

#### `/policies`
Contains Azure Policy definitions and management scripts.

**Expected contents:**
- Custom policy definitions (JSON files)
- Policy assignment scripts
- Policy compliance reporting scripts

#### `/governance`
Contains scripts for Azure governance and compliance operations.

**Expected contents:**
- RBAC management scripts
- Audit and monitoring configurations
- Cost management and billing scripts

#### `/networking`
Contains scripts for Azure networking operations.

**Expected contents:**
- Virtual network management
- Network security group configuration
- VPN and ExpressRoute management

#### `/security`
Contains scripts for Azure security operations.

**Expected contents:**
- Azure Defender configuration
- Security Center compliance scripts
- Key Vault management

#### `/automation`
Contains automation runbooks and scheduled tasks.

**Expected contents:**
- Scheduled backup scripts
- Maintenance automation
- Health check automation

---

## Prerequisites

### Global Requirements
- PowerShell 5.1 or higher
- Azure CLI or Azure PowerShell modules
- Active Azure subscription(s) in supported regions
- Appropriate Azure RBAC permissions for resource operations

### Module Installation

Install all required Azure modules:
```powershell
Install-Module -Name Az.Accounts -Force
Install-Module -Name Az.Compute -Force
Install-Module -Name Az.Resources -Force
```

### Authentication

Scripts support both:
- Interactive login with Multi-Factor Authentication (MFA)
- Service Principal authentication (when configured)

---

## Usage Guidelines

### Best Practices

1. **Always verify target resources** before executing power operations
2. **Run scripts during maintenance windows** to minimize operational impact
3. **Test scripts in non-production environments** first
4. **Monitor logs** for operation success/failure
5. **Keep Azure modules updated** for security and feature updates

### Error Handling

All scripts include comprehensive error handling:
- Validation of Azure context before operations
- Graceful failure messages
- Exit codes for automation integration
- Detailed error information in output

### Logging and Auditing

Scripts provide:
- Console output for real-time feedback
- Operation status indicators
- Azure Activity Log integration (automatically)
- Command history for audit trails

---

## Multi-Cloud Support

### Azure Commercial
- **Environment Name:** AzureCloud
- **Endpoint:** https://management.azure.com
- **Use Case:** Production and commercial deployments

### Azure Government
- **Environment Name:** AzureUSGovernment
- **Endpoint:** https://management.usgovcloudapi.net
- **Use Case:** US Government and FedRAMP compliance

Scripts automatically detect and handle environment-specific configurations.

---

## Related Resources

- **Parent Directory:** `../` - Contains utility scripts for Azure Defender and Bastion configurations
- **AzureDefenderforCloud-PolicyClone:** Policy management for Azure Defender
- **BastionRemoteDesktop:** Azure Bastion connection management

---

## Changelog

### Version 2.0.0 - January 3, 2026

**New Features:**
- Added intelligent Azure context detection
- Implemented smart environment switching
- Added support for Azure Government environment
- Enhanced VM status display before actions
- Added Restart operation for virtual machines
- Improved user interface with color-coded output

**Improvements:**
- Streamlined workflow by removing redundant confirmation prompts
- Enhanced error messages with actionable guidance
- Added helper functions for environment name resolution
- Improved code organization with function documentation

**Bug Fixes:**
- Fixed context detection for users with multiple cloud logins
- Resolved subscription filtering issues

**Dependencies Updated:**
- Now requires Az.Accounts and Az.Compute modules

---

### Version 1.0.0 - December 2025

**Initial Release:**
- Basic VM power state management
- Subscription and resource group selection
- Interactive VM selection
- Power on/off operations
- Multi-confirmation workflow
- Support for Azure Commercial environment

---

## Support and Contribution

### Reporting Issues

If you encounter issues:
1. Verify Azure module versions are current
2. Check Azure RBAC permissions
3. Review Azure Activity Log for error details
4. Ensure proper network connectivity to Azure endpoints

### Future Enhancements

Planned features for upcoming releases:
- Scheduled VM operations (start at specific times)
- Batch VM operations across multiple VMs
- Cost reporting integration
- Azure Monitor integration
- Automated backup verification
- Bulk policy application
- Cross-subscription operations

---

## License

These scripts are provided as-is for Azure resource management operations.

---

## Change Log

| Date | Version | Changes |
|------|---------|---------|
| 2026-01-03 | 1.0 | Initial custom initiative deployment |

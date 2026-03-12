// ============================================================================
// Module: VM Login RBAC — Assign Virtual Machine Administrator Login role
//
// Grants the specified principal the ability to log in to a VM using Entra ID
// credentials with admin privileges.
//
// Role: Virtual Machine Administrator Login
// GUID: 1c0163c0-47e6-4577-8991-ea5c82e286e4
// ============================================================================

@description('Name of the VM to assign the role on')
param vmName string

@description('Entra ID object ID of the principal to grant VM admin login')
param principalId string

@description('Principal type (User, Group, or ServicePrincipal)')
@allowed(['User', 'Group', 'ServicePrincipal'])
param principalType string = 'User'

// Virtual Machine Administrator Login built-in role
var vmAdminLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = {
  name: vmName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, principalId, vmAdminLoginRoleId)
  scope: vm
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmAdminLoginRoleId)
    principalId: principalId
    principalType: principalType
  }
}

output roleAssignmentId string = roleAssignment.id

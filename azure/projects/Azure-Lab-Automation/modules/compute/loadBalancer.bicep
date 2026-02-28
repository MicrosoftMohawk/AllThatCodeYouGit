// ============================================================================
// Module: Internal Load Balancer for AOAG Listener
// Deploys a Standard-SKU internal LB with frontend IP, backend pool,
// health probe, and LB rule with Floating IP (DSR) enabled.
// ============================================================================

@description('Name of the load balancer')
param lbName string

@description('Azure region for deployment')
param location string

@description('Resource ID of the subnet for the frontend IP')
param subnetId string

@description('Static private IP address for the AOAG listener (frontend)')
param frontendIp string

@description('TCP port for the health probe')
param probePort int = 59999

@description('SQL listener port (frontend and backend)')
param lbPort int = 1433

@description('Health probe interval in seconds')
param probeIntervalSeconds int = 5

@description('Number of consecutive probe failures before marking unhealthy')
param probeNumberOfProbes int = 2

@description('Idle timeout in minutes for the LB rule')
param idleTimeoutMinutes int = 30

@description('Tags to apply to all resources')
param tags object = {}

// ---------------------------------------------------------------------------
// Internal Load Balancer
// ---------------------------------------------------------------------------
resource lb 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: lbName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-listener'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: frontendIp
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'be-sqlnodes'
      }
    ]
    probes: [
      {
        name: 'hp-aoag'
        properties: {
          protocol: 'Tcp'
          port: probePort
          intervalInSeconds: probeIntervalSeconds
          numberOfProbes: probeNumberOfProbes
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'lbr-aoag-${lbPort}'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'fe-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-sqlnodes')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'hp-aoag')
          }
          protocol: 'Tcp'
          frontendPort: lbPort
          backendPort: lbPort
          enableFloatingIP: true
          idleTimeoutInMinutes: idleTimeoutMinutes
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output lbId string = lb.id
output lbName string = lb.name
output backendPoolId string = lb.properties.backendAddressPools[0].id
output frontendIpConfigId string = lb.properties.frontendIPConfigurations[0].id

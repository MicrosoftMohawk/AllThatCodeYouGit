// ============================================================================
// Module: Availability Set
// Deploys an Aligned-SKU availability set for managed-disk VMs
// ============================================================================

@description('Name of the availability set')
param name string

@description('Azure region for deployment')
param location string

@description('Number of fault domains')
@minValue(1)
@maxValue(3)
param faultDomainCount int = 2

@description('Number of update domains')
@minValue(1)
@maxValue(20)
param updateDomainCount int = 5

@description('Tags to apply')
param tags object = {}

// ---------------------------------------------------------------------------
// Availability Set
// ---------------------------------------------------------------------------
resource avset 'Microsoft.Compute/availabilitySets@2024-03-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Aligned'
  }
  properties: {
    platformFaultDomainCount: faultDomainCount
    platformUpdateDomainCount: updateDomainCount
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output availabilitySetId string = avset.id
output availabilitySetName string = avset.name

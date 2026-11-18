targetScope = 'resourceGroup'

@description('Existing demo VNet in this resource group.')
param vnetName string = 'ado-repro-vnet'

@description('Existing subnet for private endpoints.')
param subnetName string = 'pe-subnet'

@description('Existing demo Key Vault name.')
param vaultName string

param endpointName string = 'pe-ado-repro-ca-vault'
param location string = resourceGroup().location

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: subnetName
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'ado-repro'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: endpointName
  location: location
  properties: {
    subnet: { id: subnet.id }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: { privateDnsZoneId: zone.id }
      }
    ]
  }
}

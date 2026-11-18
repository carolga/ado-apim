targetScope = 'resourceGroup'

@description('West US 3 is supported by both this repo and the pinned Foundry foundation template. Verify regional availability before deploying.')
@allowed([
  'westus3'
  'canadacentral'
])
param location string = 'westus3'

@description('Deploy the dedicated foundation initially; set false for subsequent gateway-only experiments.')
param deployFoundation bool = true

@description('Provision a private jumpbox and Bastion. Enable for the initial deployment in a new resource group.')
param deployJumpbox bool = false

@description('Enable the private-CA hostname only after generating its matching PFX.')
param enablePrivateCaGateway bool = false

@secure()
param gatewayCertificateData string = ''

@secure()
param gatewayCertificatePassword string = ''

param azureDevOpsOrganization string
param vscodeOAuthClientId string
param publisherName string
param publisherEmail string

@description('Object ID of the operator who will upload the public CA secret. Not an application/client ID.')
param operatorObjectId string

param privateDnsZoneName string = 'repro.test'
param gatewayHostLabel string = 'mcp'

@description('Adjust these non-overlapping ranges if connecting this VNet to an existing network.')
param vnetAddressPrefix string = '10.87.0.0/16'
param agentSubnetPrefix string = '10.87.0.0/24'
param peSubnetPrefix string = '10.87.1.0/24'
param jumpSubnetPrefix string = '10.87.2.0/27'
param bastionSubnetPrefix string = '10.87.3.0/26'

@description('Leave true for infrastructure preparation; explicitly deploy a supported model before testing the Foundry agent.')
param skipModelDeployment bool = true
param modelName string = 'gpt-4.1-mini'
param modelVersion string = '2025-04-14'
@minValue(1)
param modelCapacity int = 1

var suffix = take(uniqueString(resourceGroup().id), 4)
var accountPrefix = 'adorepro'
var accountName = '${accountPrefix}${suffix}'
var projectName = 'ado-repro-${suffix}'
var vnetName = 'ado-repro-vnet'
var gatewayHostname = '${gatewayHostLabel}.${privateDnsZoneName}'
var tags = {
  purpose: 'ado-foundry-ca-repro'
  'managed-by': 'bicep'
}

module accessNetwork './access-network.bicep' = if (deployFoundation && deployJumpbox) {
  name: 'ado-repro-access-network'
  params: {
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    jumpSubnetPrefix: jumpSubnetPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
    tags: tags
  }
}

// Pinned Microsoft sample, rather than a second hand-maintained capability-host implementation.
#disable-next-line no-deployments-resources
resource foundation 'Microsoft.Resources/deployments@2022-09-01' = if (deployFoundation) {
  name: 'ado-repro-foundation'
  properties: {
    mode: 'Incremental'
    templateLink: {
      uri: 'https://raw.githubusercontent.com/microsoft-foundry/foundry-samples/ce52cffdbd91716723b06eb1bce39f964a23ed45/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup/azuredeploy.json'
    }
    parameters: {
      location: { value: location }
      aiServices: { value: accountPrefix }
      firstProjectName: { value: 'ado-repro-' }
      vnetName: { value: vnetName }
      vnetAddressPrefix: { value: vnetAddressPrefix }
      agentSubnetPrefix: { value: agentSubnetPrefix }
      peSubnetPrefix: { value: peSubnetPrefix }
      existingVnetResourceId: { value: deployJumpbox ? accessNetwork!.outputs.vnetResourceId : '' }
      reuseExistingSubnets: { value: deployJumpbox }
      enableContainerRegistry: { value: false }
      createAccountCapabilityHost: { value: false }
      skipModelDeployment: { value: skipModelDeployment }
      modelName: { value: modelName }
      modelVersion: { value: modelVersion }
      modelCapacity: { value: modelCapacity }
    }
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: foundry
  name: projectName
}

module jumpbox './jumpbox.bicep' = if (deployJumpbox) {
  name: 'ado-repro-jumpbox'
  params: {
    location: location
    vnetName: vnetName
    operatorObjectId: operatorObjectId
    tags: tags
  }
  dependsOn: [foundation, accessNetwork]
}

resource operatorFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployJumpbox) {
  name: guid(project.id, operatorObjectId, 'foundry-user')
  scope: project
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
    principalId: operatorObjectId
    principalType: 'User'
  }
  dependsOn: [foundation]
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-ado-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource foundrySecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, foundry.id, 'ca-reader')
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: foundry.identity.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [foundation]
}

resource operatorSecretWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, operatorObjectId, 'ca-writer')
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: operatorObjectId
    principalType: 'User'
  }
}

module observability '../modules/observability.bicep' = {
  name: 'ado-repro-observability'
  params: {
    name: 'ado-repro-${suffix}'
    location: location
    tags: tags
    retentionInDays: 30
  }
}

module apim '../modules/apim.bicep' = {
  name: 'ado-repro-apim'
  params: {
    name: 'apim-ado-repro-${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
    publisherName: publisherName
    publisherEmail: publisherEmail
    skuName: 'Developer'
    capacity: 1
    applicationInsightsConnectionString: observability.outputs.applicationInsightsConnectionString
    gatewayHostname: enablePrivateCaGateway ? gatewayHostname : ''
    gatewayCertificateData: gatewayCertificateData
    gatewayCertificatePassword: gatewayCertificatePassword
  }
}

module apis '../modules/apim-apis.bicep' = {
  name: 'ado-repro-apis'
  params: {
    apimName: apim.outputs.name
    gatewayUrl: apim.outputs.gatewayUrl
    loggerId: apim.outputs.loggerId
    tenantId: tenant().tenantId
    azureDevOpsOrganization: azureDevOpsOrganization
    vscodeOAuthClientId: vscodeOAuthClientId
    hostedAdoMcpReadOnly: true
    hostedAdoMcpToolsets: 'core'
    diagnosticSamplingPercentage: 100
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: 'ado-repro'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
  dependsOn: [foundation]
}

resource gatewayRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZone
  name: gatewayHostLabel
  properties: {
    ttl: 60
    aRecords: [
      {
        ipv4Address: first(apim.outputs.publicIpAddresses)
      }
    ]
  }
}

output foundryAccountId string = foundry.id
output foundryProjectName string = projectName
output foundryProjectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output keyVaultName string = vault.name
output publicProxyUrl string = apis.outputs.proxyUrl
output publicNativeMcpUrl string = apis.outputs.mcpExperimentUrl
output privateCaProxyUrl string = 'https://${gatewayHostname}/ado-remote-mcp-proxy'
output privateCaNativeMcpUrl string = 'https://${gatewayHostname}/ado-remote-mcp-experiment/mcp'
output privateCaGatewayEnabled bool = enablePrivateCaGateway
output vnetResourceId string = vnet.id
output jumpboxVmName string = deployJumpbox ? jumpbox!.outputs.vmName : ''
output bastionName string = deployJumpbox ? jumpbox!.outputs.bastionName : ''

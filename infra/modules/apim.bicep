targetScope = 'resourceGroup'

@description('Globally unique APIM service name.')
@minLength(1)
@maxLength(50)
param name string

@description('Azure region for APIM.')
param location string = resourceGroup().location

@description('Tags applied to APIM.')
param tags object = {}

@description('APIM publisher organization name.')
param publisherName string

@description('APIM publisher monitored role mailbox.')
param publisherEmail string

@description('APIM SKU name.')
param skuName string

@description('APIM scale unit count.')
param capacity int

@description('Application Insights connection string used by the APIM logger.')
param applicationInsightsConnectionString string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: capacity
  }
  properties: {
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
    }
    disableGateway: false
    publicNetworkAccess: 'Enabled'
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'None'
  }
}

resource applicationInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    credentials: {
      connectionString: applicationInsightsConnectionString
    }
    description: 'Workspace-based Application Insights logger'
    isBuffered: false
    loggerType: 'applicationInsights'
  }
}

output name string = apim.name
output id string = apim.id
output gatewayUrl string = apim.properties.gatewayUrl
output loggerId string = applicationInsightsLogger.id

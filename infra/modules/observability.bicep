targetScope = 'resourceGroup'

@description('Environment name used to derive observability resource names.')
param name string

@description('Azure region for the resources.')
param location string = resourceGroup().location

@description('Tags applied to the resources.')
param tags object = {}

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

var resourceToken = take(uniqueString(subscription().id, resourceGroup().id, name, location), 13)

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'log-${resourceToken}'
  location: location
  tags: tags
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: retentionInDays
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${resourceToken}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    IngestionMode: 'LogAnalytics'
    Request_Source: 'rest'
    WorkspaceResourceId: workspace.id
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output workspaceCustomerId string = workspace.properties.customerId
output applicationInsightsId string = applicationInsights.id
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString

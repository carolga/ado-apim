targetScope = 'subscription'

@description('Short azd environment name used for deterministic naming and tagging.')
@minLength(1)
@maxLength(40)
param environmentName string

@description('Azure region for all resources.')
@allowed([
  'centralus'
  'westus3'
  'canadacentral'
])
param location string = 'centralus'

@description('Additional non-sensitive tags applied to resources.')
param tags object = {}

@description('Microsoft Entra tenant used by the Azure DevOps organization.')
param tenantId string

@description('Azure DevOps organization name as one URL-safe path segment, not a URL.')
@minLength(1)
@maxLength(64)
param azureDevOpsOrganization string

@description('Organization name displayed as the APIM publisher.')
@minLength(1)
param publisherName string

@description('Monitored organizational role mailbox used as the APIM publisher email.')
@minLength(3)
param publisherEmail string

@description('APIM SKU. Developer is POC-only; StandardV2 and PremiumV2 are production candidates.')
@allowed([
  'Developer'
  'StandardV2'
  'PremiumV2'
])
param apimSkuName string = 'Developer'

@description('APIM scale unit count.')
@minValue(1)
param apimCapacity int = 1

@description('Maximum accepted calls in each rate-limit period.')
@minValue(1)
param rateLimitCalls int = 60

@description('Rate-limit renewal period in seconds.')
@minValue(1)
param rateLimitPeriod int = 60

@description('Percentage of APIM requests sampled into Application Insights.')
@minValue(0)
@maxValue(100)
param diagnosticSamplingPercentage int = 100

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param diagnosticRetentionInDays int = 30

@description('Comma-separated hosted Azure DevOps MCP toolsets enforced by APIM.')
@minLength(1)
param hostedAdoMcpToolsets string = 'all'

@description('Whether APIM asks the hosted Azure DevOps MCP server to expose read-only tools only.')
param hostedAdoMcpReadOnly bool = true

var resourceToken = take(uniqueString(subscription().id, environmentName, location, 'ado-mcp-v2'), 10)
var resourceBase = 'v2-${resourceToken}'
var resourceGroupName = 'rg-ado-mcp-${resourceBase}'
var commonTags = union(tags, {
  'azd-env-name': environmentName
  architecture: 'apim-ado-mcp-proxy'
  'managed-by': 'azd'
  SecurityControl: 'Ignore'
  CostControl: 'Ignore'
})
var validatedOrganizationName = uriComponent(azureDevOpsOrganization) == azureDevOpsOrganization && !contains(azureDevOpsOrganization, '/') && azureDevOpsOrganization != '.' && azureDevOpsOrganization != '..'
  ? azureDevOpsOrganization
  : fail('azureDevOpsOrganization must be one URL-safe path segment.')

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

module observability './modules/observability.bicep' = {
  name: 'observability'
  scope: resourceGroup
  params: {
    name: resourceBase
    location: location
    tags: commonTags
    retentionInDays: diagnosticRetentionInDays
  }
}

module apim './modules/apim.bicep' = {
  name: 'apim'
  scope: resourceGroup
  params: {
    name: 'apim-${resourceBase}'
    location: location
    tags: commonTags
    publisherName: publisherName
    publisherEmail: publisherEmail
    skuName: apimSkuName
    capacity: apimCapacity
    applicationInsightsConnectionString: observability.outputs.applicationInsightsConnectionString
  }
}

module adoMcpProxy './modules/apim-apis.bicep' = {
  name: 'ado-mcp-proxy'
  scope: resourceGroup
  params: {
    apimName: apim.outputs.name
    gatewayUrl: apim.outputs.gatewayUrl
    loggerId: apim.outputs.loggerId
    tenantId: tenantId
    azureDevOpsOrganization: validatedOrganizationName
    hostedAdoMcpToolsets: hostedAdoMcpToolsets
    hostedAdoMcpReadOnly: hostedAdoMcpReadOnly
    rateLimitCalls: rateLimitCalls
    rateLimitPeriod: rateLimitPeriod
    diagnosticSamplingPercentage: diagnosticSamplingPercentage
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output AZURE_RESOURCE_GROUP_ID string = resourceGroup.id
output APIM_NAME string = apim.outputs.name
output APIM_GATEWAY_URL string = apim.outputs.gatewayUrl
output ADO_REMOTE_MCP_PROXY_URL string = adoMcpProxy.outputs.proxyUrl
output ADO_REMOTE_MCP_BACKEND_URL string = adoMcpProxy.outputs.backendUrl
output APPLICATION_INSIGHTS_RESOURCE_ID string = observability.outputs.applicationInsightsId
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = observability.outputs.workspaceId
output HOSTED_ADO_MCP_TOOLSETS string = hostedAdoMcpToolsets
output HOSTED_ADO_MCP_READONLY string = string(hostedAdoMcpReadOnly)

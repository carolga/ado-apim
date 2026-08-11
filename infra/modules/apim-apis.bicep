targetScope = 'resourceGroup'

@description('Name of the APIM service.')
param apimName string

@description('APIM gateway URL.')
param gatewayUrl string

@description('Resource ID of the APIM Application Insights logger.')
param loggerId string

@description('Azure DevOps organization name as one URL-safe path segment, not a URL.')
@minLength(1)
@maxLength(64)
param azureDevOpsOrganization string

@description('Comma-separated hosted Azure DevOps MCP toolsets enforced by APIM.')
@minLength(1)
param hostedAdoMcpToolsets string = 'all'

@description('Whether APIM asks the hosted Azure DevOps MCP server to expose read-only tools only.')
param hostedAdoMcpReadOnly bool = true

@description('Maximum accepted calls in each rate-limit period.')
@minValue(1)
param rateLimitCalls int = 60

@description('Rate-limit renewal period in seconds.')
@minValue(1)
param rateLimitPeriod int = 60

@description('Percentage of requests sampled into Application Insights.')
@minValue(0)
@maxValue(100)
param diagnosticSamplingPercentage int = 100

var proxyApiName = 'ado-remote-mcp-proxy'
var proxyPath = 'ado-remote-mcp-proxy'
var backendUrl = 'https://mcp.dev.azure.com/${azureDevOpsOrganization}'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource readOnlyNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-readonly'
  properties: {
    displayName: 'ado-remote-mcp-readonly'
    secret: false
    value: string(hostedAdoMcpReadOnly)
  }
}

resource toolsetsNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-toolsets'
  properties: {
    displayName: 'ado-remote-mcp-toolsets'
    secret: false
    value: hostedAdoMcpToolsets
  }
}

resource rateLimitCallsNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-rate-limit-calls'
  properties: {
    displayName: 'ado-remote-mcp-rate-limit-calls'
    secret: false
    value: string(rateLimitCalls)
  }
}

resource rateLimitPeriodNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-rate-limit-period'
  properties: {
    displayName: 'ado-remote-mcp-rate-limit-period'
    secret: false
    value: string(rateLimitPeriod)
  }
}

resource proxyApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: proxyApiName
  properties: {
    apiType: 'http'
    displayName: 'Azure DevOps MCP Proxy'
    description: 'Transparent HTTP pass-through to the Azure DevOps-hosted remote MCP endpoint.'
    path: proxyPath
    protocols: [
      'https'
    ]
    serviceUrl: backendUrl
    subscriptionRequired: false
    type: 'http'
  }
}

resource proxyPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: proxyApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/ado-remote-mcp-policy.xml')
  }
  dependsOn: [
    rateLimitCallsNamedValue
    rateLimitPeriodNamedValue
    readOnlyNamedValue
    toolsetsNamedValue
  ]
}

resource proxyPostOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: proxyApi
  name: 'mcp-post'
  properties: {
    displayName: 'MCP streamable HTTP POST'
    method: 'POST'
    urlTemplate: '/'
    responses: [
      {
        statusCode: 200
      }
      {
        statusCode: 401
      }
    ]
  }
}

resource proxyDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: proxyApi
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    backend: {
      request: {
        body: {
          bytes: 0
        }
        headers: []
      }
      response: {
        body: {
          bytes: 0
        }
        headers: []
      }
    }
    frontend: {
      request: {
        body: {
          bytes: 0
        }
        headers: []
      }
      response: {
        body: {
          bytes: 0
        }
        headers: []
      }
    }
    httpCorrelationProtocol: 'W3C'
    logClientIp: false
    loggerId: loggerId
    metrics: true
    operationNameFormat: 'Name'
    sampling: {
      percentage: diagnosticSamplingPercentage
      samplingType: 'fixed'
    }
    verbosity: 'error'
  }
  dependsOn: [
    proxyPolicy
    proxyPostOperation
  ]
}

output proxyApiId string = proxyApi.id
output proxyUrl string = '${gatewayUrl}/${proxyPath}'
output backendUrl string = backendUrl

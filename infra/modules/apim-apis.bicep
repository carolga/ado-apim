targetScope = 'resourceGroup'

@description('Name of the APIM service.')
param apimName string

@description('APIM gateway URL.')
param gatewayUrl string

@description('Resource ID of the APIM Application Insights logger.')
param loggerId string

@description('Microsoft Entra tenant used by the Azure DevOps organization.')
param tenantId string

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
var oauthApiName = 'ado-remote-mcp-oauth'
var backendUrl = 'https://mcp.dev.azure.com/${azureDevOpsOrganization}'
var metadataUrl = '${gatewayUrl}/.well-known/oauth-protected-resource/${proxyPath}'
var authorizationServerUrl = gatewayUrl

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource tenantNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-tenant-id'
  properties: {
    displayName: 'ado-remote-mcp-tenant-id'
    secret: false
    value: tenantId
  }
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

resource resourceUrlNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-resource-url'
  properties: {
    displayName: 'ado-remote-mcp-resource-url'
    secret: false
    value: backendUrl
  }
}

resource metadataUrlNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-resource-metadata-url'
  properties: {
    displayName: 'ado-remote-mcp-resource-metadata-url'
    secret: false
    value: metadataUrl
  }
}

resource authorizationServerNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-remote-mcp-authorization-server'
  properties: {
    displayName: 'ado-remote-mcp-authorization-server'
    secret: false
    value: authorizationServerUrl
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
    metadataUrlNamedValue
    rateLimitCallsNamedValue
    rateLimitPeriodNamedValue
    readOnlyNamedValue
    resourceUrlNamedValue
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

resource oauthApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: oauthApiName
  properties: {
    apiType: 'http'
    displayName: 'Azure DevOps MCP OAuth Compatibility'
    description: 'OAuth discovery facade for VS Code when the hosted Azure DevOps MCP endpoint is accessed through the APIM hostname.'
    path: ''
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    type: 'http'
  }
}

resource protectedResourceMetadataOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: oauthApi
  name: 'get-ado-remote-mcp-protected-resource-metadata'
  properties: {
    displayName: 'Get hosted Azure DevOps MCP protected-resource metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource/${proxyPath}'
    responses: [
      {
        statusCode: 200
      }
    ]
  }
}

resource authorizationServerMetadataOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: oauthApi
  name: 'get-ado-remote-mcp-authorization-server-metadata'
  properties: {
    displayName: 'Get hosted Azure DevOps MCP authorization-server metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-authorization-server'
    responses: [
      {
        statusCode: 200
      }
    ]
  }
}

resource authorizeOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: oauthApi
  name: 'authorize-ado-remote-mcp-client'
  properties: {
    displayName: 'Authorize hosted Azure DevOps MCP client'
    method: 'GET'
    urlTemplate: '/authorize'
    responses: [
      {
        statusCode: 302
      }
    ]
  }
}

resource tokenOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: oauthApi
  name: 'exchange-ado-remote-mcp-token'
  properties: {
    displayName: 'Exchange hosted Azure DevOps MCP authorization code'
    method: 'POST'
    urlTemplate: '/token'
    responses: [
      {
        statusCode: 200
      }
      {
        statusCode: 400
      }
    ]
  }
}

resource registerOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: oauthApi
  name: 'register-ado-remote-mcp-client'
  properties: {
    displayName: 'Register hosted Azure DevOps MCP client'
    method: 'POST'
    urlTemplate: '/register'
    responses: [
      {
        statusCode: 201
      }
    ]
  }
}

resource protectedResourceMetadataPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: protectedResourceMetadataOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/ado-remote-mcp-oauth-policy.xml')
  }
  dependsOn: [
    authorizationServerNamedValue
    resourceUrlNamedValue
    tenantNamedValue
  ]
}

resource authorizationServerMetadataPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: authorizationServerMetadataOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/ado-remote-mcp-oauth-policy.xml')
  }
  dependsOn: [
    authorizationServerNamedValue
    resourceUrlNamedValue
    tenantNamedValue
  ]
}

resource authorizePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: authorizeOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/ado-remote-mcp-oauth-policy.xml')
  }
  dependsOn: [
    authorizationServerNamedValue
    resourceUrlNamedValue
    tenantNamedValue
  ]
}

resource tokenPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: tokenOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/ado-remote-mcp-oauth-policy.xml')
  }
  dependsOn: [
    authorizationServerNamedValue
    resourceUrlNamedValue
    tenantNamedValue
  ]
}

resource registerPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: registerOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/ado-remote-mcp-oauth-policy.xml')
  }
  dependsOn: [
    authorizationServerNamedValue
    resourceUrlNamedValue
    tenantNamedValue
  ]
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

resource oauthDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: oauthApi
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
    authorizationServerMetadataPolicy
    authorizePolicy
    protectedResourceMetadataPolicy
    registerPolicy
    tokenPolicy
  ]
}

output proxyApiId string = proxyApi.id
output proxyUrl string = '${gatewayUrl}/${proxyPath}'
output backendUrl string = backendUrl

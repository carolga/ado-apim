# Deployment guide

This is an infrastructure-only deployment. `azure.yaml` points azd at the subscription-scoped `infra/main.bicep`; it defines no application services or deployment hooks.

## Prerequisites

- Azure CLI with Bicep available (`az bicep version`).
- Azure Developer CLI **1.18.0 or later**, as required by `azure.yaml`.
- PowerShell 7 or later for the validation script and examples.
- An Azure subscription and permissions to create a resource group at subscription scope and deploy API Management, Log Analytics, and Application Insights within it. Required resource providers must be registered (`Microsoft.ApiManagement`, `Microsoft.OperationalInsights`, and `Microsoft.Insights`), or you must have permission to register them.
- An Entra-backed Azure DevOps organization and a user with organization/project permissions.
- The manual [Entra enterprise application and public client setup](../README.md#microsoft-entra-setup), including redirects and required resource consent. Provisioning does not create these objects.
- HTTPS connectivity from clients to APIM and Microsoft sign-in, and from APIM to `mcp.dev.azure.com` and `login.microsoftonline.com`.

The template enables public APIM access with no VNet integration. It is not a private-network deployment.

## Configure

Run from the repository root, replacing placeholders with your values:

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
azd auth login --tenant-id <tenant-id>

azd env new <environment-name> --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION centralus
azd env set AZURE_TENANT_ID <tenant-id>
azd env set AZURE_DEVOPS_ORGANIZATION <organization-name>
azd env set VS_CODE_PUBLIC_CLIENT_ID <public-client-app-id>
azd env set APIM_PUBLISHER_NAME "<publisher-name>"
azd env set APIM_PUBLISHER_EMAIL <publisher-email>
azd env set APIM_SKU_NAME Developer
azd env set APIM_CAPACITY 1
azd env set MCP_RATE_LIMIT_CALLS 60
azd env set MCP_RATE_LIMIT_PERIOD 60
azd env set DIAGNOSTIC_SAMPLING_PERCENTAGE 100
azd env set LOG_ANALYTICS_RETENTION_DAYS 30
```

Use the Azure DevOps organization's **name only**, not a URL or a path with slashes. The tenant must match the organization's Entra setup. `AZURE_TENANT_ID` configures the OAuth facade; it does not itself switch the Azure CLI or azd login.

### Configuration reference

`infra/main.parameters.json` maps the following values:

| azd value | Bicep parameter | Constraint or intended starting value |
|---|---|---|
| `AZURE_ENV_NAME` | `environmentName` | Set by `azd env new`; 1-40 characters at the Bicep layer |
| `AZURE_LOCATION` | `location` | `centralus`, `westus3`, or `canadacentral` |
| `AZURE_TENANT_ID` | `tenantId` | Tenant used for Entra authorize/token endpoints |
| `AZURE_DEVOPS_ORGANIZATION` | `azureDevOpsOrganization` | 1-64 characters; one URL-safe segment, not `.` or `..` |
| `VS_CODE_PUBLIC_CLIENT_ID` | `vscodeOAuthClientId` | Existing public/native client application ID |
| `APIM_PUBLISHER_NAME` | `publisherName` | Nonempty publisher name |
| `APIM_PUBLISHER_EMAIL` | `publisherEmail` | Publisher contact mailbox; Bicep only checks minimum length 3 |
| `APIM_SKU_NAME` | `apimSkuName` | `Developer`, `StandardV2`, or `PremiumV2` |
| `APIM_CAPACITY` | `apimCapacity` | Integer >= 1; service/SKU limits still apply |
| `MCP_RATE_LIMIT_CALLS` | `rateLimitCalls` | Integer >= 1; start with 60 |
| `MCP_RATE_LIMIT_PERIOD` | `rateLimitPeriod` | Integer >= 1, seconds; start with 60; APIM policy limits still apply |
| `DIAGNOSTIC_SAMPLING_PERCENTAGE` | `diagnosticSamplingPercentage` | Integer 0-100; start with 100 |
| `LOG_ANALYTICS_RETENTION_DAYS` | `diagnosticRetentionInDays` | Integer 30-730; start with 30; workspace service limits still apply |

`AZURE_SUBSCRIPTION_ID` selects the deployment subscription through azd, rather than a Bicep parameter. Set all mapped values above: the checked-in parameter file uses environment substitutions even for parameters with Bicep defaults.

Additional Bicep parameters are not mapped in that file:

| Parameter | Default | Effect |
|---|---|---|
| `hostedAdoMcpReadOnly` | `true` | Overrides upstream `X-MCP-Readonly` |
| `hostedAdoMcpToolsets` | `all` | Overrides upstream `X-MCP-Toolsets`; minimum length 1 |
| `tags` | `{}` | Additional resource tags |

To change them through this azd deployment, add their values to `infra/main.parameters.json` before provisioning, for example as entries inside its `parameters` object:

```json
"hostedAdoMcpReadOnly": { "value": true },
"hostedAdoMcpToolsets": { "value": "repos,wit" }
```

Setting an arbitrary azd variable alone will not change an unmapped parameter. Toolset names and read-only enforcement are implemented by the hosted server, not validated by this template.

Resource names are generated from subscription ID, environment name, and location, including `rg-ado-mcp-v2-<token>` and `apim-v2-<token>`. Changing these inputs changes the names; it does not move or automatically clean up an earlier deployment. Built-in tags override colliding entries in `tags`, including `SecurityControl: Ignore` and `CostControl: Ignore`; review these values against your organizational requirements.

## Validate and provision

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1
```

Do not continue if the script exits nonzero. It parses JSON/XML/PowerShell, compiles the four Bicep files, and checks source hygiene and selected text patterns. It is not an ARM deployment validation, APIM policy-expression validator, OAuth test, or MCP interoperability test.

The script filters absolute paths using directory exclusions. If the checkout is under `.copilot`, `.azure`, `.github`, or another excluded directory, source checks can skip files. Run it in a checkout outside those directory names and confirm JSON/XML parsing and a nonzero file count in the hygiene scan.

The native MCP experiment currently produces Bicep warnings `BCP037` (`backendId`) and `BCP036` (`mcpProperties.endpoints`). A successful compiler exit does not resolve those warnings or establish that Azure accepts the preview schema. The experiment is deployed unconditionally alongside the HTTP proxy.

Provision Azure resources only after reviewing those limitations:

```powershell
azd provision --no-prompt
```

This creates billable resources; Developer is the development/test default, not a production SLA choice. A successful provision is still not an end-to-end authentication/tool-call check.

## Outputs

Read outputs from the selected azd environment:

```powershell
azd env get-value ADO_REMOTE_MCP_PROXY_URL
azd env get-value ADO_REMOTE_MCP_BACKEND_URL
azd env get-value ADO_REMOTE_MCP_EXPERIMENT_URL
```

| Output | Meaning |
|---|---|
| `AZURE_RESOURCE_GROUP`, `AZURE_RESOURCE_GROUP_ID` | Created resource group name and ARM ID |
| `APIM_NAME`, `APIM_GATEWAY_URL` | APIM name and gateway origin |
| `ADO_REMOTE_MCP_PROXY_URL` | HTTP proxy URL to use in VS Code |
| `ADO_REMOTE_MCP_BACKEND_URL` | Direct hosted backend, including organization |
| `ADO_REMOTE_MCP_EXPERIMENT_URL` | Native MCP experiment; not the supported client URL |
| `APPLICATION_INSIGHTS_RESOURCE_ID` | Application Insights ARM ID |
| `AZURE_LOG_ANALYTICS_WORKSPACE_ID` | Workspace **ARM resource ID**, not its customer/workspace GUID |
| `HOSTED_ADO_MCP_TOOLSETS`, `HOSTED_ADO_MCP_READONLY` | Configured upstream header values (read-only output is a string) |

## Verify the deployment

Run an unauthenticated POST using PowerShell 7:

```powershell
$url = azd env get-value ADO_REMOTE_MCP_PROXY_URL
$response = Invoke-WebRequest `
  -Uri $url `
  -Method Post `
  -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"validation","version":"1.0"}}}' `
  -ContentType 'application/json' `
  -Headers @{ Accept = 'application/json, text/event-stream' } `
  -SkipHttpErrorCheck
$response.StatusCode
$response.Headers['WWW-Authenticate']
```

Expect status `401` and this **APIM-rewritten**, not unchanged backend, challenge:

```text
Bearer resource_metadata="https://<apim-host>/.well-known/oauth-protected-resource/ado-remote-mcp-proxy"
```

Check discovery and the static registration response:

```powershell
$gateway = (azd env get-value APIM_GATEWAY_URL).TrimEnd('/')
Invoke-RestMethod "$gateway/.well-known/oauth-protected-resource/ado-remote-mcp-proxy"
Invoke-RestMethod "$gateway/.well-known/oauth-authorization-server"
Invoke-RestMethod "$gateway/register" -Method Post -ContentType 'application/json' -Body '{}'
```

The protected resource should be `https://mcp.dev.azure.com`; its authorization server and authorize/token/register URLs should use the APIM gateway. Registration should return the configured `VS_CODE_PUBLIC_CLIENT_ID` and the two redirect URIs listed in the [Entra setup](../README.md#public-client-application-for-vs-code).

Finally, follow the [VS Code configuration](../README.md#vs-code-configuration), complete sign-in, discover tools, and **invoke a read-only tool** against an accessible project. Discovery alone does not prove that downstream Azure DevOps authorization works. No automated runtime verification is included in this repository.

## Remove deployed resources

When the environment is no longer needed, select the correct azd environment and review the resources before running:

```powershell
azd down
```

This is destructive and removes deployed resources, including telemetry resources. Manually configured Entra applications and consent are outside this deployment and are not removed by it.

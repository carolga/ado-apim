# Azure DevOps MCP through Azure API Management

This repository contains Azure infrastructure and APIM policies, not an application server. It provisions an HTTP proxy to the hosted Azure DevOps MCP endpoint:

```text
VS Code / GitHub Copilot
  -> https://<apim-host>/ado-remote-mcp-proxy
  -> https://mcp.dev.azure.com/<organization>
  -> Azure DevOps
```

Azure DevOps authorizes requests using the signed-in user's delegated token. APIM forwards that token, but **rewrites backend `401` challenges** to use an APIM-hosted OAuth discovery and compatibility facade. It does not simply pass authentication challenges through unchanged.

## What gets deployed

- One resource group containing a public Azure API Management service, Log Analytics workspace, and workspace-based Application Insights.
- An HTTPS HTTP API at `/ado-remote-mcp-proxy`, with a single `POST /` operation.
- An APIM root API providing protected-resource metadata, authorization-server metadata, `/register`, `/authorize`, and `/token`.
- An experimental native MCP API at `/ado-remote-mcp-experiment/mcp`, using the `2025-09-01-preview` API version. It is deployed unconditionally, not enabled by a feature flag.
- APIM named values and policies for read-only/toolset request headers, per-IP rate limiting on the MCP APIs, correlation IDs, selected header removal, and authentication compatibility.
- Application Insights diagnostics on all three APIs, configured with zero request/response body bytes, no selected headers, and `logClientIp: false`.

The deployment does **not** create an application backend, Entra app registration, enterprise application, consent grant, private network, or shared service caller. There are no application build or service deployment steps in `azure.yaml`; deployment uses `azd provision`.

Start with the [deployment guide](docs/deployment-guide.md) for all required settings, then use the VS Code configuration below. The [architecture reference](docs/architecture-plan.md) explains the routes, OAuth flow, and policy boundaries.

## Microsoft Entra setup

These are **manual prerequisites**, not resources created by Bicep. Use the tenant associated with the Azure DevOps organization, and a user with access to the relevant organization, projects, and resources.

### Azure DevOps MCP enterprise application

The tenant needs the Azure DevOps MCP service principal (application ID `2a72489c-aab2-4b65-b93a-a91edccf33b8`). Follow Microsoft's [remote MCP troubleshooting guide](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server-troubleshooting?view=azure-devops#cant-find-the-azure-devops-mcp-enterprise-application-in-the-tenant).

Check whether it exists:

```powershell
az login --tenant <tenant-id> --allow-no-subscriptions
az ad sp show --id 2a72489c-aab2-4b65-b93a-a91edccf33b8 `
  --query "{appId:appId,displayName:displayName,accountEnabled:accountEnabled}"
```

If it is missing, an appropriately authorized tenant administrator can create it:

```powershell
az ad sp create --id 2a72489c-aab2-4b65-b93a-a91edccf33b8
```

Creating the service principal does not grant users access to Azure DevOps or guarantee that a custom client is permitted by tenant/resource policies.

### Public client application for VS Code

Create or select a public/native client app registration in the same tenant. Set its application ID as `VS_CODE_PUBLIC_CLIENT_ID`. Configure these public-client redirect URIs, which are hard-coded in the `/register` policy response:

```text
http://127.0.0.1:33418/
https://vscode.dev/redirect
```

Configure delegated access to the Azure DevOps MCP resource. Check the resource's currently exposed permissions in your tenant before adding consent; the repository does not provision or validate them:

```powershell
az ad sp show --id 2a72489c-aab2-4b65-b93a-a91edccf33b8 `
  --query "{appId:appId,scopes:oauth2PermissionScopes}"
```

For tenants exposing `Ado.Mcp.Tools`, select that delegated permission on the client app and grant consent as required by tenant policy. If the permission is unavailable or the resource rejects the client, resolve that with the tenant/resource administrator; deploying APIM does not enable it.

Verify the client configuration:

```powershell
az ad app show --id <public-client-app-id> `
  --query "{appId:appId,displayName:displayName,publicClient:publicClient,requiredResourceAccess:requiredResourceAccess}"
```

The APIM `/register` endpoint returns this **existing client ID**; it does not dynamically create a registration or validate the submitted registration body.

## VS Code configuration

After following the [deployment guide](docs/deployment-guide.md), get the supported HTTP proxy URL:

```powershell
azd env get-value ADO_REMOTE_MCP_PROXY_URL
```

Run **MCP: Open User Configuration** from the VS Code Command Palette and add this server. Merge it into an existing `servers` object rather than replacing other entries:

```json
{
  "servers": {
    "ado-mcp-apim-proxy": {
      "type": "http",
      "url": "https://<apim-host>/ado-remote-mcp-proxy"
    }
  }
}
```

Replace the URL with the exact deployment output. This configuration uses the APIM registration facade; do not add an `oauth.clientId` override to this example. The resource audience is `https://mcp.dev.azure.com`, while the backend URL includes the organization path.

Run **MCP: List Servers**, select `ado-mcp-apim-proxy`, and start or restart it. Sign in with an Entra account authorized for the organization. In Copilot Chat's **Agent** mode, inspect the available tools and try a read-only request such as:

```text
List the Azure DevOps projects I can access.
```

Tool discovery is not proof of working authorization: also invoke a read-only tool against a project you can access. See the [verification steps](docs/deployment-guide.md#verify-the-deployment).

## Configuration and limitations

The complete environment-variable and Bicep parameter reference is in the [deployment guide](docs/deployment-guide.md#configuration-reference).

- Defaults are `centralus`, APIM `Developer` with one unit, 60 calls per 60 seconds per client IP on the MCP policies, 100% diagnostic sampling, and 30-day workspace retention. The parameter file explicitly requires environment values for these settings; do not assume Bicep defaults populate missing azd values.
- Allowed regions are `centralus`, `westus3`, and `canadacentral`. Allowed SKUs are `Developer`, `StandardV2`, and `PremiumV2`; `BasicV2` is not accepted. Developer is for development/testing, not a production SLA.
- Bicep defaults `hostedAdoMcpReadOnly` to `true` and `hostedAdoMcpToolsets` to `all`. These parameters are **not mapped to azd environment variables** in the checked-in parameter file.
- Read-only/toolset behavior is requested through upstream headers, not implemented as an APIM tool-level authorization check. The policy does not parse JSON-RPC or authorize individual tools; Azure DevOps remains the authorization boundary.
- Only MCP `POST` is defined on the HTTP proxy. There are no proxy `GET`, `DELETE`, or `OPTIONS` operations, no separate SSE listener, and no CORS policy. Do not assume complete Streamable HTTP session management or arbitrary browser-client support.
- The native MCP experiment uses a separate APIM backend connection. Its policy still points `401` discovery at the HTTP proxy's resource metadata. Do not substitute `ADO_REMOTE_MCP_EXPERIMENT_URL` for the supported VS Code endpoint without independent authentication and tool-call checks.
- Static compilation currently warns about the experiment's `backendId` and `mcpProperties.endpoints` shape. Compilation is not evidence that Azure accepts those preview resources or that native MCP tool calls work. The experiment is part of every provision operation, so a rejection can affect the overall deployment.
- The APIs require no APIM subscription key, and the gateway has public network access with no VNet integration. The OAuth facade does not use the MCP rate-limit/header-hygiene policy or inherit inbound global policies through `<base />`.
- Zero body/header diagnostic capture is not a guarantee of zero sensitive telemetry. Request URLs and other telemetry may still be recorded, and existing/inherited APIM policies can affect behavior. Review logging before production use.

## Troubleshooting

For an unauthenticated proxy POST, expect a `401` challenge referring to:

```text
https://<apim-host>/.well-known/oauth-protected-resource/ado-remote-mcp-proxy
```

If VS Code reports **Dynamic Client Registration not supported**, check the deployed discovery and `/register` routes first. It can also indicate stale client discovery state; it is not proof of a cache problem.

Stop old entries for the same APIM host with **MCP: List Servers**, keep only the current configuration, remove old `oauth` overrides, and run **MCP: Reset Trust** if available in your VS Code version. Then run **Developer: Reload Window** and restart the server. A new server ID can help isolate old state. Avoid editing VS Code's internal state databases.

For sign-in failures, check the configured tenant, public client redirects, resource permission/consent, and the error returned by Entra. For tool-call failures after sign-in, check Azure DevOps project permissions and compare with the direct hosted endpoint. Do not infer successful tool invocation from a successful `initialize` or `tools/list`.

The MCP policies overwrite `X-MCP-Toolsets` but do not remove a caller's `X-MCP-Tools` header. Microsoft documents those headers as mutually exclusive; do not send `X-MCP-Tools` with this configuration. Consult the [upstream troubleshooting guide](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server-troubleshooting?view=azure-devops) for current hosted-server requirements.

## Validation and costs

Run `pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1` from a normal checkout. It checks JSON/XML/PowerShell syntax, compiles Bicep using Azure CLI, and runs text/hygiene checks. It does not deploy resources, validate APIM policy expressions in Azure, or test OAuth or MCP tool calls.

**Validator path limitation:** its exclusion regexes match the entire absolute path. A checkout anywhere under a directory named `.copilot`, `.azure`, `.github`, or another excluded name can skip source enumeration and produce misleading results (including a zero-file hygiene pass and failed content checks). Run the same script from a checkout outside those paths; do not treat a zero-file pass as validation. See the [deployment guide](docs/deployment-guide.md#validate-and-provision) for expected checks.

APIM is the primary fixed infrastructure cost; Log Analytics/Application Insights add usage-based telemetry costs. This repository contains no pricing lookup or cost validation. Use the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for the chosen supported SKU, region, capacity, ingestion, and retention rather than relying on a fixed monthly estimate. The experiment and OAuth facade use the same APIM service, not separate gateway instances.

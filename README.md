# Azure DevOps MCP through Azure API Management

This repository deploys one working implementation:

```text
VS Code / GitHub Copilot
  -> Azure API Management
  -> hosted Azure DevOps MCP endpoint
  -> Azure DevOps
```

APIM acts as a governed HTTP proxy for the GA hosted Azure DevOps MCP endpoint at `https://mcp.dev.azure.com/<organization>`. Azure DevOps remains the OAuth resource server and authorizes every request as the signed-in user.

## What gets deployed

- Azure API Management
- Log Analytics and workspace-based Application Insights
- A raw APIM HTTP API at `/ado-remote-mcp-proxy`
- APIM policies for:
  - HTTPS enforcement
  - per-IP rate limiting
  - `X-MCP-Readonly`
  - `X-MCP-Toolsets`
  - header hygiene
  - zero body logging

The deployment does **not** create an application backend, app registration, client credential, or shared service caller.

## Microsoft Entra requirements

This APIM proxy uses the hosted Azure DevOps MCP OAuth resource. VS Code discovers APIM as the authorization server facade, APIM performs Dynamic Client Registration compatibility, and Microsoft Entra issues a delegated user token for Azure DevOps MCP.

You need two Entra objects configured before users can sign in successfully.

### 1. Azure DevOps MCP enterprise application

The tenant must contain the **Azure DevOps MCP** enterprise application:

```text
Application ID: 2a72489c-aab2-4b65-b93a-a91edccf33b8
Display name: Azure DevOps MCP
```

Microsoft documents this enterprise app ID in the [remote Azure DevOps MCP Server troubleshooting guide](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server-troubleshooting?view=azure-devops#cant-find-the-azure-devops-mcp-enterprise-application-in-the-tenant).

If it is missing, a tenant administrator with Application Administrator, Cloud Application Administrator, or Global Administrator permissions can create the service principal:

```powershell
az login --tenant <tenant-id> --allow-no-subscriptions
az ad sp create --id 2a72489c-aab2-4b65-b93a-a91edccf33b8
```

Verify it exists:

```powershell
az ad sp show --id 2a72489c-aab2-4b65-b93a-a91edccf33b8 `
  --query "{appId:appId,displayName:displayName,accountEnabled:accountEnabled}"
```

Expected values:

```json
{
  "appId": "2a72489c-aab2-4b65-b93a-a91edccf33b8",
  "displayName": "Azure DevOps MCP",
  "accountEnabled": true
}
```

### 2. VS Code public client application

APIM returns this public client ID from its `/register` compatibility endpoint. Configure the value through `VS_CODE_PUBLIC_CLIENT_ID`.

The app registration must be a public/native client and must include these redirect URIs:

```text
http://127.0.0.1:33418/
https://vscode.dev/redirect
```

The app registration must also request delegated access to the **Azure DevOps MCP** resource:

```text
Resource app ID: 2a72489c-aab2-4b65-b93a-a91edccf33b8
Delegated permission: Ado.Mcp.Tools
Permission ID: f8dac17a-2c07-463d-a820-8956dc52dfb5
```

Example CLI setup for an existing public client app:

```powershell
$clientAppId = "<VS_CODE_PUBLIC_CLIENT_ID>"
$resourceAppId = "2a72489c-aab2-4b65-b93a-a91edccf33b8"
$scopeId = "f8dac17a-2c07-463d-a820-8956dc52dfb5"

$app = az ad app show --id $clientAppId | ConvertFrom-Json
$required = @($app.requiredResourceAccess)

$required = @($required | Where-Object { $_.resourceAppId -ne $resourceAppId })
$required += [pscustomobject]@{
  resourceAppId = $resourceAppId
  resourceAccess = @(
    [pscustomobject]@{
      id = $scopeId
      type = "Scope"
    }
  )
}

$path = Join-Path $env:TEMP "ado-mcp-required-resource-access.json"
$required | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
az ad app update --id $clientAppId --required-resource-accesses "@$path"
```

Grant admin consent if tenant policy requires it:

```powershell
az ad app permission admin-consent --id <VS_CODE_PUBLIC_CLIENT_ID>
```

Verify the public client redirects:

```powershell
az ad app show --id <VS_CODE_PUBLIC_CLIENT_ID> `
  --query "{appId:appId,displayName:displayName,publicClient:publicClient}"
```

## VS Code configuration

After deployment, get the APIM-hosted MCP proxy URL:

```powershell
azd env get-value ADO_REMOTE_MCP_PROXY_URL
```

Use that value in VS Code. The final configuration should look like this:

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

Do not configure `oauth.clientId` for this proxy. APIM exposes a minimal OAuth compatibility facade for VS Code at `/.well-known/oauth-authorization-server`, `/register`, `/authorize`, and `/token`. The facade returns the configured `VS_CODE_PUBLIC_CLIENT_ID` during Dynamic Client Registration, then redirects/token-exchanges against Microsoft Entra for the hosted Azure DevOps MCP resource. That public-client app must include the VS Code redirect URIs `http://127.0.0.1:33418/` and `https://vscode.dev/redirect`. The OAuth resource is `https://mcp.dev.azure.com`; the backend MCP URL still includes the organization path. APIM forwards the resulting delegated user token unchanged to Azure DevOps.

### Why this is an APIM HTTP API, not an APIM MCP server

Azure API Management has a product feature for exposing an existing remote MCP server as an APIM MCP server. That is the preferred product direction when the APIM MCP passthrough preserves the upstream MCP server's authentication flow, tool catalog, sessions, and streaming behavior.

This repository uses a plain APIM HTTP API proxy at `/ado-remote-mcp-proxy` because the hosted Azure DevOps MCP endpoint is already a complete remote MCP server. In live testing, the APIM MCP passthrough resource did not surface the hosted Azure DevOps MCP behavior correctly for this scenario. Specifically, it returned an empty tool catalog during unauthenticated tool discovery and did not give VS Code the same authentication behavior as the hosted Azure DevOps endpoint.

The HTTP API proxy keeps APIM in the gateway role:

- APIM forwards MCP JSON-RPC traffic to `https://mcp.dev.azure.com/<organization>`.
- APIM applies enterprise controls such as rate limiting, read-only/toolset headers, header hygiene, diagnostics, and no body logging.
- APIM provides only the minimal OAuth compatibility facade that VS Code needs when the MCP server URL is on the APIM hostname.
- Azure DevOps MCP still owns tool behavior, token validation, user authorization, and audit semantics.

If APIM's existing-MCP passthrough later preserves the hosted Azure DevOps MCP auth and tool catalog end-to-end, this repo should be simplified to use the APIM MCP resource type. Until then, the HTTP API proxy is the working and most transparent implementation.

### Experimental APIM MCP passthrough endpoint

The deployment also includes an experimental APIM MCP passthrough endpoint so you can test the product-native shape side by side:

```powershell
azd env get-value ADO_REMOTE_MCP_EXPERIMENT_URL
```

Expected path:

```text
https://<apim-host>/ado-remote-mcp-experiment/mcp
```

Use this only for comparison testing. Keep `ADO_REMOTE_MCP_PROXY_URL` as the known-good endpoint unless the experimental MCP endpoint proves that authentication, tool discovery, sessions, and tool calls all work end-to-end.

### Add the server in VS Code

1. Open VS Code.
2. Press `Ctrl+Shift+P` to open the Command Palette.
3. Run **MCP: Open User Configuration**.
4. Add the `ado-mcp-apim-proxy` server entry shown above. If the file already has a `servers` object, add only the inner server entry instead of replacing the whole file.
5. Replace `https://<apim-host>/ado-remote-mcp-proxy` with the exact `ADO_REMOTE_MCP_PROXY_URL` output.
6. Save the file.
7. Press `Ctrl+Shift+P` again.
8. Run **MCP: List Servers**.
9. Select `ado-mcp-apim-proxy`.
10. Choose **Start Server** or **Restart Server**.
11. When VS Code prompts for authentication, sign in with the Microsoft Entra account that has access to the Azure DevOps organization.
12. After sign-in completes, open GitHub Copilot Chat, switch to **Agent** mode, and open the tools picker to confirm Azure DevOps tools are available.

### Test prompts

Try simple read-only prompts first:

```text
List the Azure DevOps projects I can access.
```

```text
Show my assigned work items.
```

```text
What pull requests require my review?
```

If tools do not appear, run **MCP: List Servers**, restart `ado-mcp-apim-proxy`, and reload the VS Code window.

### Troubleshoot stale OAuth discovery

If VS Code shows **Dynamic Client Registration not supported** and names the authorization server as your APIM root, for example `https://<apim-host>/`, VS Code is using stale OAuth discovery from an older MCP entry or the `/register` operation has not been deployed. The current proxy should challenge with APIM-hosted resource metadata:

```text
WWW-Authenticate: Bearer resource_metadata="https://<apim-host>/.well-known/oauth-protected-resource/ado-remote-mcp-proxy"
```

Use this reset sequence:

1. Select **Cancel** in the Dynamic Client Registration dialog.
2. Press `Ctrl+Shift+P`.
3. Run **MCP: List Servers**.
4. Stop or disable any old MCP entries for the same APIM host.
5. Run **MCP: Reset Trust**.
6. Open **MCP: Open User Configuration** and make sure only the current proxy entry remains for this APIM host. Remove any `oauth` block from this server entry.
7. Rename the server ID if needed, for example from `azure-devops-hosted-via-apim` to `ado-mcp-apim-proxy`, so VS Code treats it as a new MCP server.
8. Run **Developer: Reload Window**.
9. Run **MCP: List Servers**, select `ado-mcp-apim-proxy`, and choose **Start Server**.

Do not click **Copy URIs & Proceed** for this proxy unless you intentionally want to register and manage your own OAuth public client. The expected flow uses APIM's `/register` compatibility response and should not require manual client registration.

#### Where VS Code stores stale MCP auth state

VS Code persists MCP trust, dynamic OAuth providers, client registrations, and per-workspace MCP usage in SQLite state databases under the user profile:

```text
%APPDATA%\Code\User\globalStorage\state.vscdb
%APPDATA%\Code\User\workspaceStorage\<workspace-id>\state.vscdb
```

On this machine those expand to paths like:

```text
C:\Users\<user>\AppData\Roaming\Code\User\globalStorage\state.vscdb
C:\Users\<user>\AppData\Roaming\Code\User\workspaceStorage\<workspace-id>\state.vscdb
```

The stale rows we found were in the `ItemTable` table. Relevant keys/prefixes included:

```text
dynamicAuthProviders
secret://dynamicAuthProvider:clientRegistration:<authorization-server> <mcp-server-url>
secret://{"isDynamicAuthProvider":true,...}
mcpserver-<authorization-server> <mcp-server-url>-<account>
mcp.config.<scope>.<server-name>-<authorization-server> <mcp-server-url>
<authorization-server> <mcp-server-url>-<account>-mcpserver-usages
```

If Command Palette reset steps do not clear the issue, close VS Code fully, back up the `state.vscdb` files, and remove only rows containing the affected APIM hostname. Do not delete unrelated rows unless you are intentionally resetting broader VS Code state.

## Configuration

Required azd values:

```powershell
azd env set AZURE_LOCATION centralus
azd env set AZURE_DEVOPS_ORGANIZATION <organization-name>
azd env set AZURE_TENANT_ID <tenant-id>
azd env set VS_CODE_PUBLIC_CLIENT_ID <public-client-app-id>
azd env set APIM_PUBLISHER_NAME <publisher-name>
azd env set APIM_PUBLISHER_EMAIL <publisher-email>
azd env set APIM_SKU_NAME Developer
azd env set APIM_CAPACITY 1
azd env set MCP_RATE_LIMIT_CALLS 60
azd env set MCP_RATE_LIMIT_PERIOD 60
azd env set DIAGNOSTIC_SAMPLING_PERCENTAGE 100
azd env set LOG_ANALYTICS_RETENTION_DAYS 30
```

Optional Bicep parameters:

| Parameter | Default | Purpose |
|---|---:|---|
| `hostedAdoMcpReadOnly` | `true` | Sends `X-MCP-Readonly: true` to Azure DevOps |
| `hostedAdoMcpToolsets` | `all` | Sends `X-MCP-Toolsets` to Azure DevOps |

## Cost estimate

The table below assumes **Central US** (`centralus` / US Central), one APIM unit, 730 hours per month, USD retail pricing, and the default deployment shape in this repository. Actual cost can vary by discounts, commitment plans, traffic, telemetry volume, retention, taxes, and future Azure price changes.

| Resource | Default in this repo | Central US retail meter used | Approx monthly cost |
|---|---:|---:|---:|
| API Management Developer | Yes | `$0.0658/hour` | `$48.03/month` |
| Log Analytics ingestion | Usage-based | `$0` for the initial tier shown by the retail API, then `$2.76/GB` above that tier | Depends on GB ingested |
| Log Analytics retention | 30 days | Included for the default 30-day retention used here | `$0` for default retention |
| Application Insights | Workspace-based | Data is billed through Log Analytics ingestion/retention | Depends on telemetry volume |

For quick planning:

| APIM SKU option | Central US hourly rate | Approx monthly cost at 730 hours | Notes |
|---|---:|---:|---|
| Developer | `$0.0658/hour` | `$48.03/month` | Lowest-cost test/dev option; not intended for production SLA. |
| Basic v2 | `$0.20548/hour` | `$150.00/month` | Lower-cost managed gateway option for small workloads. |
| Standard v2 | `$0.9589/hour` | `$700.00/month` | More appropriate production starting point for many internal deployments. |
| Premium v2 | `$3.83562/hour` | `$2,800.00/month` | Higher isolation/scale option. |

This proxy has no application backend compute cost because it does not deploy a web app, container app, function app, registry, database, or queue. The dominant fixed cost is APIM. The variable cost is usually observability data volume.

## Deploy

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1
azd provision --no-prompt
```

## Verify

Unauthenticated MCP initialize should return a `401` with the hosted Azure DevOps MCP protected-resource metadata:

```powershell
$url = azd env get-value ADO_REMOTE_MCP_PROXY_URL
Invoke-WebRequest `
  -Uri $url `
  -Method Post `
  -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"validation","version":"1.0"}}}' `
  -ContentType 'application/json' `
  -Headers @{ Accept = 'application/json, text/event-stream' } `
  -SkipHttpErrorCheck
```

The `WWW-Authenticate` response should point at the APIM-hosted resource metadata:

- `https://<apim-host>/.well-known/oauth-protected-resource/ado-remote-mcp-proxy`

## Policy reference

The solution has two APIM policy files. They are deliberately small because APIM should govern the edge and preserve the user's Azure DevOps authentication context, not become a custom Azure DevOps client.

### `infra/policies/ado-remote-mcp-policy.xml`

This policy is attached to the `/ado-remote-mcp-proxy` API. It governs calls to the hosted Azure DevOps MCP endpoint.

| Line(s) | Policy | Why it is needed |
|---:|---|---|
| 1 | `<policies>` | Root APIM policy document element. APIM rejects policy files without this wrapper. |
| 2 | `<inbound>` | Starts policy logic that runs before the request is sent to Azure DevOps. All request validation and request header shaping belongs here. |
| 3 | `<base />` | Preserves any APIM global policy behavior. Without it, API-level policy would replace inherited global controls. |
| 4 | `<choose>` | Creates a conditional block for request validation. |
| 5 | HTTPS scheme check | Rejects any request APIM sees as non-HTTPS. Remote MCP authentication and bearer tokens must not be accepted over plain HTTP. |
| 6 | `<return-response>` | Stops processing immediately when the HTTPS requirement fails. |
| 7 | `400 HTTPS Required` | Returns a clear client error instead of forwarding an invalid request to Azure DevOps. |
| 8 | `Cache-Control: no-store` | Prevents clients or intermediaries from caching an error response related to an authenticated endpoint. |
| 9-11 | Close HTTPS validation block | Ends the early rejection branch and resumes normal processing for HTTPS requests. |
| 12 | `set-variable correlation-id` | Creates a safe correlation ID that APIM can echo back without logging user data. |
| 13 | Read `X-Correlation-ID` | Lets a trusted test client provide a correlation ID for troubleshooting. |
| 14 | `Guid parsed;` | Ensures only GUID-formatted values are accepted. |
| 15 | `Guid.TryParse...` fallback | Uses the supplied GUID if valid; otherwise falls back to APIM's request ID. This avoids header injection or arbitrary tracking values. |
| 16 | Close correlation variable | Ends the APIM C# expression block. |
| 17-19 | `rate-limit-by-key` | Applies a configurable per-IP rate limit before traffic reaches Azure DevOps. `Retry-After` helps clients back off correctly. |
| 20 | `X-MCP-Readonly` | Sends the configured read-only setting to the hosted Azure DevOps MCP endpoint. The default is `true` so tool discovery excludes mutating tools. |
| 21 | `<choose>` | Starts optional toolset filtering logic. |
| 22 | Toolsets non-empty check | Only sends `X-MCP-Toolsets` when the configured value exists. This avoids emitting an empty governance header. |
| 23 | `X-MCP-Toolsets` | Restricts which Azure DevOps MCP tool groups are available, for example `repos,wit,pipelines` or `all`. |
| 24-25 | Close toolset block | Ends optional toolset header logic. |
| 26 | Delete `Forwarded` | Removes client-supplied forwarding metadata that could spoof original protocol, host, or client chain. |
| 27 | Delete `X-Forwarded-For` | Prevents callers from spoofing client IP data forwarded to the backend. |
| 28 | Delete `X-Forwarded-Host` | Prevents callers from spoofing the original host. |
| 29 | Delete `X-Forwarded-Proto` | Prevents callers from spoofing the original protocol. |
| 30 | Delete `X-Forwarded-Port` | Prevents callers from spoofing the original port. |
| 31 | Delete `X-Original-Host` | Removes another common original-host spoofing header. |
| 32 | Delete `X-Original-URL` | Removes a common upstream rewrite/original URL header. |
| 33 | Delete `X-Rewrite-URL` | Removes a common rewrite-target spoofing header. |
| 34 | Delete `Proxy-Authorization` | Ensures proxy credentials are never forwarded to Azure DevOps. |
| 35 | Delete `Proxy-Connection` | Removes hop-by-hop proxy behavior that should not reach the backend. |
| 36 | Delete `X-MS-CLIENT-PRINCIPAL` | Prevents callers from spoofing platform-injected identity headers. |
| 37 | Delete `X-MS-CLIENT-PRINCIPAL-ID` | Prevents callers from spoofing a platform principal ID. |
| 38 | Delete `X-MS-TOKEN-AAD-ACCESS-TOKEN` | Prevents callers from smuggling an alternate platform token header. |
| 39 | Delete `Ocp-Apim-Trace` | Prevents callers from enabling APIM tracing. |
| 40 | Delete `Ocp-Apim-Trace-Location` | Prevents callers from providing or receiving trace location metadata. |
| 41 | Set `X-Correlation-ID` | Sends only the normalized correlation ID downstream and back to clients. |
| 42 | `</inbound>` | Ends request-side processing. |
| 43 | `<backend>` | Starts backend forwarding behavior. |
| 44 | `forward-request` options | Forwards to Azure DevOps without following redirects, request-body buffering, or response buffering. This is important for MCP streamable HTTP behavior and auth challenge preservation. |
| 45 | `</backend>` | Ends backend forwarding behavior. |
| 46 | `<outbound>` | Starts response-side processing after Azure DevOps responds. |
| 47 | `<base />` | Preserves inherited outbound policies. |
| 48-54 | 401 challenge rewrite | Points VS Code to APIM-hosted protected-resource metadata for this proxy. This is required because VS Code performs OAuth discovery against the APIM hostname when the MCP server URL is an APIM URL. |
| 55 | `Cache-Control: no-store` | Prevents caching of MCP responses and authentication challenges. |
| 56 | Set `X-Correlation-ID` | Echoes the normalized correlation ID on successful and error responses. |
| 57 | `</outbound>` | Ends response-side processing. |
| 58 | `<on-error>` | Starts policy logic for APIM-side failures. |
| 59 | `<base />` | Preserves inherited error handling. |
| 60 | `Cache-Control: no-store` | Prevents APIM-generated errors from being cached. |
| 61-63 | Error `X-Correlation-ID` | Returns the normalized correlation ID if available; otherwise returns APIM's request ID. |
| 64 | `</on-error>` | Ends APIM error handling. |
| 65 | `</policies>` | Ends the APIM policy document. |

### `infra/policies/ado-remote-mcp-oauth-policy.xml`

This policy is attached to the APIM root metadata and OAuth compatibility operations. It exists because VS Code treats the APIM origin as the MCP authorization server when the MCP server URL is hosted behind APIM.

| Line(s) | Policy | Why it is needed |
|---:|---|---|
| 1 | `<policies>` | Root APIM policy document element. |
| 2 | `<inbound>` | Handles metadata, registration, authorization, and token requests before APIM routes to a backend. |
| 3 | `<choose>` | Dispatches behavior based on the requested OAuth path. |
| 4-16 | Protected-resource metadata branch | Returns metadata for `/ado-remote-mcp-proxy`, advertising the hosted Azure DevOps MCP resource and APIM as the authorization server facade. |
| 17-34 | Authorization-server metadata branch | Returns RFC-style authorization server metadata, including `/authorize`, `/token`, `/register`, PKCE support, and public-client auth mode. |
| 35-50 | Dynamic Client Registration branch | Returns the configured tenant public-client ID and VS Code redirect URIs so VS Code does not require manual client registration. |
| 51-73 | Authorization redirect branch | Redirects browser sign-in to the tenant-specific Microsoft Entra authorize endpoint, preserving VS Code's PKCE/state parameters and adding the hosted Azure DevOps MCP scope/resource when missing. |
| 74-91 | Token exchange branch | Forwards the authorization-code token exchange to the tenant-specific Microsoft Entra token endpoint, again ensuring the hosted Azure DevOps MCP scope/resource are present. |
| 92-97 | Default 404 branch | Rejects any unexpected path on the OAuth facade. |
| 100-102 | Backend/outbound/error sections | Required APIM policy sections; backend forwarding is only used by the `/token` branch after it rewrites the backend to Microsoft Entra. |

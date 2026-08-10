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
- APIM-hosted protected-resource metadata at `/.well-known/oauth-protected-resource/ado-remote-mcp-proxy`
- APIM policies for:
  - HTTPS enforcement
  - per-IP rate limiting
  - `X-MCP-Readonly`
  - `X-MCP-Toolsets`
  - header hygiene
  - zero body logging

The deployment does **not** create an application backend, app registration, client credential, or shared service caller.

## VS Code configuration

After deployment, use the `ADO_REMOTE_MCP_PROXY_URL` output:

```json
{
  "servers": {
    "azure-devops-via-apim": {
      "type": "http",
      "url": "https://<apim-host>/ado-remote-mcp-proxy"
    }
  }
}
```

Do not configure a custom `oauth.clientId`. VS Code should follow the protected-resource metadata returned by APIM, request a token for `https://mcp.dev.azure.com/.default`, and send that delegated user token through APIM to Azure DevOps.

## Configuration

Required azd values:

```powershell
azd env set AZURE_LOCATION westus3
azd env set AZURE_TENANT_ID <tenant-id>
azd env set AZURE_DEVOPS_ORGANIZATION <organization-name>
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

## Deploy

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1
azd provision --no-prompt
```

## Verify

Unauthenticated MCP initialize should return a `401` with APIM-hosted protected-resource metadata:

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

The metadata endpoint should advertise:

- `resource`: `https://mcp.dev.azure.com/<organization>`
- `authorization_servers`: your tenant-specific Entra v2 authority
- `scopes_supported`: `https://mcp.dev.azure.com/.default`

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
| 48 | `<choose>` | Adds conditional response handling. |
| 49 | `StatusCode == 401` | Detects authentication challenges from Azure DevOps. |
| 50-52 | Rewrite `WWW-Authenticate` | Points VS Code to APIM-hosted protected-resource metadata for this proxy path. This prevents VS Code from discovering unrelated APIM metadata while still advertising the Azure DevOps MCP resource. |
| 53-54 | Close challenge rewrite block | Ends conditional response handling. |
| 55 | `Cache-Control: no-store` | Prevents caching of MCP responses and authentication challenges. |
| 56 | Set `X-Correlation-ID` | Echoes the normalized correlation ID on successful and error responses. |
| 57 | `</outbound>` | Ends response-side processing. |
| 58 | `<on-error>` | Starts policy logic for APIM-side failures. |
| 59 | `<base />` | Preserves inherited error handling. |
| 60 | `Cache-Control: no-store` | Prevents APIM-generated errors from being cached. |
| 61-63 | Error `X-Correlation-ID` | Returns the normalized correlation ID if available; otherwise returns APIM's request ID. |
| 64 | `</on-error>` | Ends APIM error handling. |
| 65 | `</policies>` | Ends the APIM policy document. |

### `infra/policies/ado-remote-mcp-protected-resource-policy.xml`

This policy is attached to the metadata operation at `/.well-known/oauth-protected-resource/ado-remote-mcp-proxy`. It is intentionally a static response because the metadata values are deployment configuration.

| Line(s) | Policy | Why it is needed |
|---:|---|---|
| 1 | `<policies>` | Root APIM policy document element. |
| 2 | `<inbound>` | Handles metadata requests before APIM tries to route to any backend. |
| 3 | `<return-response>` | Makes APIM answer metadata requests directly. No backend call is needed for static OAuth metadata. |
| 4 | `200 OK` | Metadata discovery must succeed without authentication so MCP clients can start the OAuth flow. |
| 5 | `Content-Type: application/json` | Tells MCP clients to parse the response as JSON metadata. |
| 6 | `Cache-Control: no-store` | Avoids stale auth metadata after tenant, organization, or proxy URL changes. |
| 7 | `<set-body>` | Starts the JSON metadata body. |
| 8 | `resource` | Advertises the real hosted Azure DevOps MCP resource URL. Tokens should be requested for this resource, not for APIM. |
| 9 | `authorization_servers` | Points clients to the tenant-specific Microsoft Entra v2 authority. |
| 10 | `bearer_methods_supported` | States that bearer tokens are sent in the HTTP `Authorization` header. |
| 11 | `scopes_supported` | Tells clients to request `https://mcp.dev.azure.com/.default`, which is the hosted Azure DevOps MCP delegated scope. |
| 12 | End JSON body | Closes the metadata JSON object. |
| 13 | `</return-response>` | Ends direct response generation. |
| 14 | `</inbound>` | Ends inbound metadata handling. |
| 15 | `<backend><forward-request /></backend>` | Required APIM policy section. It is not reached because inbound always returns metadata. |
| 16 | `<outbound><base /></outbound>` | Required APIM policy section preserving inherited outbound behavior if ever reached. |
| 17 | `<on-error><base /></on-error>` | Required APIM policy section preserving inherited error behavior. |
| 18 | `</policies>` | Ends the APIM policy document. |

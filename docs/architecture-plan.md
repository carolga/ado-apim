# Implemented architecture

The repository is an infrastructure-only APIM deployment. Its source of truth is `infra/main.bicep`, the three modules in `infra/modules`, and the two XML policies in `infra/policies`.

```text
MCP client -- POST + delegated bearer token --> APIM HTTP proxy
                                                 |
                                                 +--> https://mcp.dev.azure.com/<organization>

MCP client -- discovery/register/authorize/token --> APIM OAuth facade
                                                        |
                                                        +--> Microsoft Entra authorize/token endpoints

APIM API diagnostics --> Application Insights --> Log Analytics workspace
```

APIM does not host Azure DevOps tools or perform tool-level authorization. It forwards MCP POSTs and participates in authentication discovery and token exchange. Azure DevOps remains the resource server and authorizes the user's actions.

## Deployed routes

All three APIM APIs have `subscriptionRequired: false` and HTTPS-only protocols.

| API | Method and path | Implementation |
|---|---|---|
| HTTP proxy | `POST /ado-remote-mcp-proxy` (operation template `/`) | Forwards to `https://mcp.dev.azure.com/<organization>` |
| OAuth facade | `GET /.well-known/oauth-protected-resource/ado-remote-mcp-proxy` | Returns resource `https://mcp.dev.azure.com`, APIM authorization-server origin, bearer-header support, and scope `https://mcp.dev.azure.com/.default` |
| OAuth facade | `GET /.well-known/oauth-authorization-server` | Advertises APIM authorize/token/register URLs, authorization code and refresh grants, S256 PKCE, and public-client authentication |
| OAuth facade | `POST /register` | Returns `201` with the configured existing public client ID and fixed VS Code redirect URIs; ignores the registration body |
| OAuth facade | `GET /authorize` | Returns `302` to the configured tenant's Entra v2 authorize endpoint |
| OAuth facade | `POST /token` | Forwards the form to the configured tenant's Entra v2 token endpoint |
| Native MCP experiment | `/ado-remote-mcp-experiment/mcp` | Preview native MCP resource with a backend at `https://mcp.dev.azure.com` and endpoint path `/<organization>` |

The HTTP proxy declares only POST, not GET/DELETE session operations or OPTIONS/CORS. Its forwarding policy disables redirects and request/response buffering; that does not make it a complete implementation of every Streamable HTTP interaction.

The experiment is always deployed. Its preview properties currently generate Bicep type warnings, and this repository has no runtime tests proving deployment acceptance, delegated authentication, or native MCP tool invocation. Its `401` policy advertises the HTTP proxy's resource metadata rather than experiment-specific metadata.

## Authentication flow

1. The client POSTs to the HTTP proxy without a token.
2. APIM forwards the request to hosted Azure DevOps MCP.
3. If the backend responds with `401`, APIM **replaces** `WWW-Authenticate` with a bearer challenge pointing to APIM's protected-resource metadata route.
4. The client retrieves the protected-resource and authorization-server metadata from APIM.
5. If the client uses registration, APIM returns `VS_CODE_PUBLIC_CLIENT_ID` and the fixed redirects `http://127.0.0.1:33418/` and `https://vscode.dev/redirect`. No Entra app is created.
6. `/authorize` passes the query parameters to Entra, adding the hosted MCP `.default` scope and resource if those parameter names are absent. Existing values, even empty ones, are not replaced.
7. Entra performs sign-in and returns control to the client redirect. APIM does not host a callback handler.
8. The client exchanges the code through APIM `/token`. The policy passes form parameters through and adds scope/resource only if absent.
9. The client retries the MCP POST with its delegated bearer token. The MCP policy does not replace the `Authorization` header; Azure DevOps validates and authorizes it.

The facade is compatibility logic for a preconfigured public client, not a general registration service. It does not validate client IDs, redirect URIs, scopes, resources, state, or PKCE values itself; OAuth validation is delegated to Entra. It advertises refresh tokens but does not itself issue tokens, persist a session, or add `offline_access` to requests. Successful refresh depends on the client request and Entra.

## MCP policy behavior

`ado-remote-mcp-policy.xml` is attached to both MCP APIs:

- Includes inherited inbound/outbound/error policies via `<base />`, but uses its own backend forwarding policy.
- Rejects requests whose original scheme is not HTTPS.
- Uses the caller's `X-Correlation-ID` only if it parses as a GUID; otherwise uses APIM's request ID. Forwards and echoes that normalized value, with a fallback in `on-error`.
- Applies `rate-limit-by-key` with key `ado-remote-mcp|<context.Request.IpAddress>`, defaults 60 calls per 60 seconds, and a `Retry-After` header. This is IP-based, not per-user; callers sharing an IP can share a budget. Both APIs use the same key expression.
- Overrides `X-MCP-Readonly` (default `true`) and `X-MCP-Toolsets` (default `all`) for interpretation by the hosted server. It does not inspect JSON-RPC methods or enforce individual tool permissions.
- Requests removal of selected forwarding, proxy, platform-identity, and tracing headers. This is not a blanket header allowlist. APIM cannot delete the client-IP portion of `X-Forwarded-For`; see the [set-header limitations](https://learn.microsoft.com/azure/api-management/set-header-policy#limitations).
- Forwards without following redirects or buffering request/response bodies.
- Rewrites backend `401` challenges, and sets `Cache-Control: no-store` and correlation headers in outbound/error processing.

The policy leaves other request headers intact, including `X-MCP-Tools`. The hosted server documents that header as mutually exclusive with `X-MCP-Toolsets`; clients should not send it with this deployment.

`ado-remote-mcp-oauth-policy.xml` is attached at the five OAuth **operations**, not as a root API-wide policy. It has no inbound `<base />`, MCP rate limiter, or MCP header-hygiene logic. Local metadata, registration, and authorization-redirect responses use `no-store`; the token branch forwards to Entra and does not explicitly set that header itself.

## Networking, diagnostics, and naming

`apim.bicep` enables the public gateway, uses `virtualNetworkType: None`, and disables the listed legacy frontend/backend TLS protocols. There is no private endpoint, managed application identity, custom hostname, APIM subscription-key requirement, or gateway JWT-validation policy in these templates.

`observability.bicep` creates a `PerGB2018` Log Analytics workspace with public ingestion/query access and workspace-based Application Insights. Each API has Application Insights diagnostics with zero body bytes, empty header capture lists, client-IP logging disabled, W3C correlation, metrics enabled, fixed sampling (default 100%), and `alwaysLog: allErrors`. Sampling does not suppress all error telemetry. These settings are not a promise that URLs or other telemetry are free of sensitive data.

The subscription template creates a resource group and deterministic resource names derived from subscription, environment, and location. It applies built-in tags, including `SecurityControl: Ignore` and `CostControl: Ignore`, after user-provided tags. Review those tags before deployment; they are labels, not implemented security or cost controls.

See the [deployment guide](deployment-guide.md) for configuration constraints, outputs, validation limits, and deployment commands.

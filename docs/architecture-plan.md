# Architecture

The architecture is intentionally small:

```text
MCP client
  -> Azure API Management
  -> hosted Azure DevOps MCP
```

APIM does not own Azure DevOps authentication. It only publishes proxy-specific protected-resource metadata so MCP clients can acquire a delegated token for the hosted Azure DevOps MCP resource.

## Request flow

1. VS Code calls `https://<apim-host>/ado-remote-mcp-proxy`.
2. APIM forwards the unauthenticated request to hosted Azure DevOps MCP.
3. Azure DevOps returns `401`.
4. APIM rewrites the challenge to APIM-hosted protected-resource metadata for the proxy path.
5. VS Code obtains a delegated token for `https://mcp.dev.azure.com/.default`.
6. VS Code retries through APIM with the user token.
7. Azure DevOps authorizes the request as the signed-in user.

## APIM responsibilities

- Enforce HTTPS.
- Apply per-IP rate limiting.
- Send `X-MCP-Readonly` and `X-MCP-Toolsets`.
- Remove proxy/client spoofing headers.
- Avoid body logging.
- Preserve user authorization to the Azure DevOps backend.

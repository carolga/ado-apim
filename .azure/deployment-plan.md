# Azure deployment inventory

This file summarizes the checked-in deployment, not an approval record or proof of a successful Azure deployment. See the [deployment guide](../docs/deployment-guide.md) for prerequisites, required environment settings, validation, and provisioning.

## Deployed shape

```text
VS Code / GitHub Copilot
  -> APIM HTTP POST proxy at /ado-remote-mcp-proxy
  -> https://mcp.dev.azure.com/<organization>

Client OAuth discovery and exchanges
  -> APIM root OAuth compatibility routes
  -> Microsoft Entra
```

The subscription-scoped Bicep deployment creates:

- A resource group.
- A public APIM service with an Application Insights logger.
- A Log Analytics workspace and workspace-based Application Insights.
- The HTTP MCP POST proxy and governance policy.
- Five OAuth discovery/registration/authorize/token operations on a root API.
- An unconditional native MCP passthrough experiment at `/ado-remote-mcp-experiment/mcp`, using preview APIM resource properties.
- Named values and API diagnostics for those APIs.

APIM forwards the delegated bearer token, but rewrites backend `401` challenges to its own protected-resource metadata. Registration returns a pre-existing public client ID. The deployment does not create Entra applications, consent, an application backend, or private networking.

## Validation status and limits

Run from the repository root:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1
```

This performs static checks and Bicep compilation only. The validator's absolute-path exclusion bug can skip source checks when the checkout is under `.copilot` or another excluded directory; use a checkout outside those paths and confirm a nonzero hygiene file count.

The native MCP experiment currently generates Bicep warnings about `backendId` and the `mcpProperties.endpoints` shape. Neither a compiler success nor this inventory establishes that Azure accepts those preview resources or that OAuth and tool calls work. Follow the [runtime verification steps](../docs/deployment-guide.md#verify-the-deployment) after provisioning; use `ADO_REMOTE_MCP_PROXY_URL`, not the experiment URL, for the documented VS Code configuration.

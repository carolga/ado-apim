# Azure Deployment Plan

> **Status:** Validated
>
> **Approved direction:** VS Code / GitHub Copilot -> Azure API Management -> hosted Azure DevOps MCP endpoint.

This repository deploys a single APIM-hosted proxy for the GA Azure DevOps remote MCP server.

## Architecture

```text
VS Code / GitHub Copilot
  -> APIM HTTP proxy at /ado-remote-mcp-proxy
  -> https://mcp.dev.azure.com/<organization>
```

APIM preserves the hosted Azure DevOps MCP authentication challenge and forwards MCP traffic to Azure DevOps. Azure DevOps authorizes actions using the signed-in user's delegated token.

## In scope

- APIM
- Log Analytics
- Application Insights
- APIM HTTP API proxy
- APIM governance policies

## Exclusions

The repository contains only APIM, logging, and policy assets for the hosted Azure DevOps MCP proxy.

## Validation proof

Run:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1
```

# Deployment guide

## Prerequisites

- Azure CLI with Bicep
- Azure Developer CLI
- PowerShell 7
- Azure permissions to deploy APIM, Log Analytics, and Application Insights
- An Azure DevOps organization connected to Microsoft Entra ID

## Configure

```powershell
az login --tenant <tenant-id>
azd auth login

azd env new <environment-name> --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
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

## Validate and deploy

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1
azd provision --no-prompt
```

## Outputs

```powershell
azd env get-value ADO_REMOTE_MCP_PROXY_URL
azd env get-value ADO_REMOTE_MCP_BACKEND_URL
```

Use `ADO_REMOTE_MCP_PROXY_URL` in VS Code MCP configuration.

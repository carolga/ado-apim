# Foundry OAuth and private-CA demos

These are opt-in diagnostic demos, not a production reference architecture or a
claim that a certificate change causes an OAuth regression. Local compilation and
offline tests do not establish that the Azure deployment or OAuth flow succeeds.

This demo attaches an MCP tool directly to a Foundry agent with OAuth identity
passthrough. It does not reproduce an MCP Server knowledge source in Foundry IQ.
Registering `trustedCertificateSources` trusts a server's private CA; it does not
configure client-certificate authentication (mTLS).

## Demos and controls

| Demo | Purpose |
| --- | --- |
| Same-token MCP comparison | Call `core_list_projects` directly, through APIM HTTP proxy, and through APIM-native MCP using one delegated token. |
| Foundry OAuth inspection | Print consent-event and tool-call summaries outside the playground without dumping tool catalogs or project contents. |
| Private-CA gateway | Add a disposable, encrypted server certificate on a private DNS hostname while retaining APIM's public-CA default hostname. |
| Foundry CA registration | Upload only the public CA PEM to Key Vault and merge a version-pinned trust reference without discarding unrelated references. |
| Private jumpbox | Optionally access the private project from a Windows VM through Azure Bastion. |

`initialize` and `tools/list` succeeding is not sufficient. The comparison must
invoke `core_list_projects`.

In one isolated deployment, the same delegated token successfully listed
projects directly and through the APIM HTTP proxy, while the APIM-native MCP
path returned `VS30063`. This observation predates the Foundry and private-CA
tests; it does not establish the cause of the customer's failure. Retest it
rather than treating it as a guaranteed outcome.

In that deployment, two Foundry Prompt agents using separate OAuth connections
also emitted consent requests. After the same user completed consent for each,
the HTTP proxy's `core_list_projects` call completed without `VS30063`, while the
APIM-native call returned `VS30063`. Both used the public-CA gateway hostname:
this reproduces an authorization failure without testing private-CA trust or the
playground's Sign-in button. The first consent attempt returned a consent-server
error; a fresh request succeeded, but the reason for the earlier error is unknown.
In a separate private-hostname control, the gateway certificate failed the
system trust check and passed with the disposable CA. Foundry returned a generic
HTTP 400 tool error before CA registration; after it accepted the version-pinned
CA, the same OAuth connection completed `core_list_projects` without `VS30063`.
The generic error did not identify TLS as its cause, so this is not proof of the
customer's failure mechanism.

## Cost and networking

Use **Developer (classic), one unit** for this non-production demo. It supports
native MCP and custom gateway certificates and has no production SLA. Consumption
is not a supported tier for APIM-native MCP. Check current regional and
subscription pricing; the other Foundry, Search, Cosmos DB, networking, Key Vault,
and logging resources also incur charges. ACR is disabled and model deployment
is skipped by default. There is no automatic shutdown or deletion.

The optional jumpbox adds a Windows VM and disk, Standard Bastion, a NAT gateway,
and two public IP addresses. These incur additional charges; Bastion and NAT remain
billable even if the VM is deallocated. The VM has no public IP. Bastion exposes
an HTTPS access gateway, while NAT provides outbound connectivity, not an egress
firewall.

The dedicated template is `infra\repro\main.bicep`; it is not referenced by
`azure.yaml`. It links the Microsoft network-secured Standard Agent Setup ARM
sample at a fixed commit, rather than copying and maintaining its capability-host
implementation. Review that upstream template before deployment:

<https://github.com/microsoft-foundry/foundry-samples/tree/ce52cffdbd91716723b06eb1bce39f964a23ed45/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup>

The foundation creates a VNet-injected Foundry account/project, private endpoints,
DNS, backing services, and monitoring. Additional APIM diagnostics use this repo's
existing observability module. Foundry ingress remains private. Enable the
optional jumpbox on the first deployment, or use an approved VPN, peered network,
or other VNet-connected workstation to run the agent diagnostic and playground.
The demo does not change organizational access policies.

With the jumpbox enabled, the template creates the VNet and its subnets before the
Foundry foundation, which reuses them without replacing them. The agent and jumpbox
subnets share outbound NAT intended to reach the internet-facing APIM gateway.
Verify that connectivity explicitly: one deployment initially resolved the
gateway name and allowed outbound traffic in its NSG, but the jumpbox could not
establish a TCP connection. A later check reached the gateway over TCP and HTTPS;
the cause of the earlier failure was not established.
The jumpbox NSG allows inbound RDP only from the Bastion subnet. Ensure all four
subnet ranges are non-overlapping and inside the VNet address space.

The APIM service remains internet-facing. A private DNS name, by default
`mcp.repro.test`, resolves to its gateway IP inside the demo VNet. Private DNS does
not make the APIM gateway private. The private certificate is selected with SNI;
the default `azure-api.net` endpoint remains the public-CA control.

West US 3 is the default because it is supported by the pinned foundation and the
existing APIM demo. Central US is not in that foundation's allowed-region list.
Verify service availability, model quota, provider registrations, permissions,
subnet ranges, and Azure Policy before provisioning. Changing region is not a
substitute for these checks.

## Local preparation only

Run from the repository root in PowerShell 7, with Python 3.10+ and Azure CLI:

```powershell
python -m venv .local\venv
& .\.local\venv\Scripts\python.exe -m pip install -r .\scripts\repro\requirements.txt
& .\.local\venv\Scripts\python.exe -m unittest discover -s .\tests -p test_repro.py -v
pwsh -NoLogo -NoProfile -File .\tests\Validate-Plan.ps1
```

These tests never invoke an agent, contact ADO, or deploy Azure resources. They
exercise protocol parsing, read-only tool selection, certificate generation,
SDK agent-endpoint selection, and a mocked Azure CLI trust update.

## Provisioning the optional environment

**The commands in this section create billable resources. They are instructions,
not part of local validation. Obtain approval before running them.**

Create a dedicated resource group in the selected subscription and copy the
example parameters into the ignored local directory:

```powershell
$subscription = "<subscription-id>"
$rg = "rg-ado-foundry-repro"
az login --tenant "<tenant-id>"
az account set --subscription $subscription
New-Item -ItemType Directory -Force .local\repro | Out-Null
Copy-Item .\infra\repro\main.parameters.example.json .\.local\repro\parameters.json
az ad signed-in-user show --query id -o tsv
```

Edit `.local\repro\parameters.json`. Supply the operator's object ID, publisher
details, public-client app ID, and ADO organization as one name, not a URL.
To provision the jumpbox, set `deployJumpbox` to `true` **before the first
foundation deployment**, in a new resource group. Do not enable it against an
already deployed foundation: its network must be created with the jumpbox subnets
and NAT before the agent subnet is in use.
The CLI public-client app needs delegated **Azure DevOps MCP / Ado.Mcp.Tools**
permission and public-client/device-code authentication enabled. Follow the main
README for the resource enterprise application and consent requirements.

The provisioning operator needs resource deployment and role-assignment
permissions, plus any data-plane provisioning roles required by the pinned
foundation. Check the current Foundry Standard Setup documentation. The template
grants the operator Key Vault Secrets Officer and the Foundry account identity
Key Vault Secrets User on the demo vault. When the jumpbox is enabled, it also
grants the operator Foundry User on the demo project and Virtual Machine
Administrator Login on the jumpbox. The template requests public vault access
with Entra/RBAC authorization; Azure Policy can override that setting. Do not
use the vault for customer or production secrets.

For runtime agent tests, explicitly set `skipModelDeployment` to `false` after
checking model availability/quota. The default requested model is
`gpt-4.1-mini`, version `2025-04-14`, GlobalStandard capacity 1. This is a
deployment request, not a guarantee of regional capacity. Capacity 1 provides
1,000 tokens per minute and can produce HTTP 429 during these agent tests; check
the deployment's actual limits and available quota before increasing capacity.

```powershell
az group create --subscription $subscription --name $rg --location westus3
az deployment group validate --subscription $subscription --resource-group $rg `
  --template-file .\infra\repro\main.bicep --parameters "@.local\repro\parameters.json"
az deployment group what-if --subscription $subscription --resource-group $rg `
  --template-file .\infra\repro\main.bicep --parameters "@.local\repro\parameters.json"
az deployment group create --subscription $subscription --resource-group $rg `
  --name ado-foundry-repro --template-file .\infra\repro\main.bicep `
  --parameters "@.local\repro\parameters.json"
az deployment group show --subscription $subscription --resource-group $rg `
  --name ado-foundry-repro --query properties.outputs -o json
```

What-if may not fully evaluate the linked foundation. Review and preview it
separately, and inspect any identity-dependent resources reported as
`Unsupported`. Validation and what-if don't guarantee that every resource
provider will accept the deployment. Save the returned endpoints and resource
IDs. Set both `deployFoundation` and `deployJumpbox` to `false` in local
parameters for subsequent gateway experiments, so the linked foundation and VM
are not reprovisioned. Incremental deployment leaves the existing jumpbox in
place. Do not retry a partially failed capability-host deployment against a
stuck delegated subnet; diagnose it first and use a fresh isolated VNet/subnet
when required by the platform.

## Connect to the optional jumpbox

In the Azure portal, open the VM identified by the `jumpboxVmName` output and
select **Connect > Bastion**. Choose RDP and **Microsoft Entra ID (Preview)**,
then sign in as the operator. Portal access also requires Reader on the VM, NIC,
and Bastion; an inherited Contributor or Owner assignment satisfies this.
Entra RDP in the portal is preview and remains subject to tenant MFA and
Conditional Access. Allow browser pop-ups for `cdn.bastion.azure.com` if needed.

The VM uses the `AADLoginForWindows` extension and has no public IP. Its required
local administrator password is generated by ARM as a secure parameter and is
not output; use Entra to sign in. If Entra login fails, diagnose the extension
and role assignments or use an authorized VM password reset rather than exposing
RDP. The image does not install this repo's Python dependencies or Azure CLI;
install approved tooling and obtain the repo inside the VM before running the
diagnostic. Verify that the Foundry project hostname resolves to its private
endpoint from the VM. The `mcp.repro.test` record resolves to APIM's **public**
gateway IP, even though its DNS zone is private. Verify TCP port 443 connectivity
to the gateway before troubleshooting TLS or OAuth; successful DNS and an
allowing NSG rule alone do not prove reachability.

## Demo 1: compare all three MCP paths

Run as a user who can list projects in the target ADO organization. Use only your
own trusted APIM endpoints: the script sends a delegated token to each URL.
Device-code sign-in prints a URL/code; it does not open a window automatically.
If tenant policy blocks this flow, stop and work with the identity administrator.
Never share device codes or disable Conditional Access.

```powershell
& .\.local\venv\Scripts\python.exe .\scripts\repro\repro.py mcp `
  --tenant-id "<tenant-id>" `
  --client-id "<public-client-app-id>" `
  --direct-url "https://mcp.dev.azure.com/<organization>" `
  --proxy-url "https://<apim-name>.azure-api.net/ado-remote-mcp-proxy" `
  --native-url "https://<apim-name>.azure-api.net/ado-remote-mcp-experiment/mcp"
```

The script uses the same token across the three paths, does not follow redirects,
and calls only `core_list_projects`. It prints summaries rather than project
contents or bearer tokens. Exit code 0 means every path reported success; 1 means
at least one path failed. Authentication/configuration exceptions stop execution
with an error rather than producing a success-shaped fallback.

## Demo 2: Foundry OAuth outside the playground

From a VNet-connected machine, create an ordinary Prompt agent with a deployed
model and one attached MCP tool. Grant the testing user the documented Foundry
data-plane role on the project.

Configure **custom OAuth identity passthrough** for the selected APIM endpoint.
Use your own OAuth app registration, the tenant's Entra authorization/token URLs,
and the hosted ADO MCP scope `https://mcp.dev.azure.com/.default` with
`offline_access`. Ensure the app has the corresponding delegated permission and
consent. Register the exact redirect URI Foundry supplies. The VS Code-only
redirects and the repo's Dynamic Client Registration compatibility facade are
not a drop-in Foundry OAuth configuration.

Foundry can restrict Microsoft-audience tokens sent to custom endpoints. If this
configuration is rejected, record that as an interoperability blocker; do not
silently switch to PATs, shared identities, or a token for the wrong audience.

Use separate, otherwise identical agents/connections for the HTTP proxy and the
native-MCP control. Keep the model, instructions, user, OAuth app/scopes, and
default deployed agent version consistent. Run each agent:

```powershell
& .\.local\venv\Scripts\python.exe .\scripts\repro\repro.py foundry `
  --tenant-id "<tenant-id>" `
  --project-endpoint "<foundryProjectEndpoint-output>" `
  --agent-name "<agent-name>"
```

Foundry sign-in and MCP OAuth are separate flows. The script explicitly requests
the initial Foundry device-code login, prints `oauth_consent_request` links if
returned, and continues the same response only after you confirm successful
consent. It never automatically approves tools. An approval request or no MCP
call exits with code 2 (incomplete), not success. Code 1 indicates a failed call.
The SDK uses `allow_preview=True` for the agent-specific endpoint.

Consent links remain sensitive; do not capture them in public transcripts or
commit terminal output. Existing server-side consent can suppress a new prompt.
Use a new connection or a different appropriately authorized test user when
checking first-use consent; InPrivate alone does not clear Foundry's consent.

## Demo 3: private-CA gateway and Foundry trust

Generate disposable certificates locally. The script prompts for a PFX password.
It writes only the public CA PEM and an encrypted gateway PFX; it does not save
the CA private key. The leaf expires after seven days.

```powershell
& .\.local\venv\Scripts\python.exe .\scripts\repro\create_certificates.py
```

Add these parameters to the ignored local parameters file without printing them
to the console. Use the same password entered during generation:

```powershell
$path = Join-Path $PWD ".local\repro\parameters.json"
$parameters = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
$password = Read-Host "Gateway PFX password" -AsSecureString
$parameters.parameters.deployFoundation.value = $false
$parameters.parameters.deployJumpbox.value = $false
$parameters.parameters.enablePrivateCaGateway.value = $true
$parameters.parameters.gatewayCertificateData = @{
  value = [Convert]::ToBase64String([IO.File]::ReadAllBytes(
    (Join-Path $PWD ".local\repro\gateway.pfx")))
}
$parameters.parameters.gatewayCertificatePassword = @{
  value = [pscredential]::new("unused", $password).GetNetworkCredential().Password
}
$parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
Remove-Variable parameters, password
```

**This local file now contains the PFX and its plaintext password.** Keep it in
the ignored directory, protect it with appropriate filesystem permissions, do
not enable shell transcription/debugging, and remove that exact file once the
gateway deployment completes. Do not commit any private keys, PFX, parameter
files containing secrets, or real diagnostic evidence.

Rerun the gateway deployment command from the provisioning section after
reviewing its what-if. Setting both deployment flags to `false` skips the
foundation and jumpbox, but does not make the deployment hostname-only: the
preview can also show changes to APIM APIs, policies, and other resources. Do not
apply unexpected changes; use an appropriately reviewed targeted update
instead. Preserve APIM custom properties and the default public-CA hostname,
and do not remove existing Foundry trust. All commands target the dedicated demo
environment.

From the VNet-connected machine, verify that `mcp.repro.test` resolves to the
APIM gateway IP. You can compare the private-CA paths directly by substituting
the `privateCaProxyUrl` and `privateCaNativeMcpUrl` outputs in Demo 1 and adding
`--ca-bundle .local\repro\ca.pem`. That option extends the CLI client's trust
only; it does not register anything in Foundry.

Use a private-CA Foundry connection with the same OAuth settings. Before
registering the CA, invoke a tool to check for a server TLS validation failure.
If it instead reaches ADO or another stage, investigate that discrepancy before
claiming a before/after certificate repro.

Register the public CA, first with `-WhatIf`, then explicitly without it:

```powershell
.\scripts\repro\Set-FoundryCaTrust.ps1 `
  -AccountId "<foundryAccountId-output>" -VaultName "<keyVaultName-output>" `
  -PublicCaPem .\.local\repro\ca.pem -WhatIf

.\scripts\repro\Set-FoundryCaTrust.ps1 `
  -AccountId "<foundryAccountId-output>" -VaultName "<keyVaultName-output>" `
  -PublicCaPem .\.local\repro\ca.pem
```

Allow propagation, then retry without changing the user or OAuth configuration.
Foundry reads the public CA secret through its account identity. The trust script
preserves other references in the same vault and refuses to replace a different
vault/source. It waits for the ARM operation to succeed and verifies the pinned
reference; an accepted request alone is not confirmation. Coordinate account
updates so no other writer races the merge. It does not delete old secret
versions or alter OAuth settings.

If vault public access is disabled, use an approved private endpoint and DNS
path to upload the PEM. The optional `infra\repro\vault-private-endpoint.bicep`
creates a vault private endpoint and a linked `privatelink.vaultcore.azure.net`
zone in the demo resource group. It incurs additional charges. First check
whether that DNS zone is already linked to the VNet; if so, use the existing
zone instead of creating a conflicting link. Review the preview before creating:

```powershell
az deployment group what-if --subscription $subscription --resource-group $rg `
  --template-file .\infra\repro\vault-private-endpoint.bicep `
  --parameters vaultName="<keyVaultName-output>"
az deployment group create --subscription $subscription --resource-group $rg `
  --name ado-repro-vault-private-endpoint `
  --template-file .\infra\repro\vault-private-endpoint.bicep `
  --parameters vaultName="<keyVaultName-output>"
```

Upload from the VNet-connected jumpbox or another approved private client. The
[private CA guidance](https://learn.microsoft.com/azure/foundry/agents/how-to/private-certificate-authority)
also directs network-restricted vaults to allow trusted Microsoft services to
bypass the firewall; the Foundry identity still requires Key Vault authorization.
Get approval before changing the firewall, and keep public access disabled.

If agent tool calls reach ADO and return `VS30063` only on the native endpoint,
while the direct and HTTP-proxy controls work, investigate delegated-token
preservation on that path. If both Foundry endpoints fail but the same-token
direct comparison succeeds, inspect Foundry connection/consent configuration.
If both direct and proxy fail, resolve token audience/permissions first.

## Evidence and cleanup

Record UTC timestamps, request/response IDs, selected endpoint path, agent
version, whether consent was requested, TLS versus HTTP failure, and the actual
read-only tool outcome. Do not collect access tokens, PFX/passwords, consent URLs,
or customer project contents. Never disable TLS verification to make a test pass.

No Azure cleanup is automatic. After the demo, review the dedicated resource
group and explicitly delete only those demo resources when authorized. Preserve
sanitized results first; Key Vault soft deletion can keep a vault name reserved.

## References

- [Foundry private CA trust](https://learn.microsoft.com/azure/foundry/agents/how-to/private-certificate-authority)
- [Foundry MCP authentication](https://learn.microsoft.com/azure/foundry/agents/how-to/mcp-authentication)
- [Foundry VNet setup](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks)
- [APIM MCP tiers](https://learn.microsoft.com/azure/api-management/mcp-server-overview)
- [APIM custom domains and certificates](https://learn.microsoft.com/azure/api-management/configure-custom-domain)
- [APIM pricing](https://azure.microsoft.com/pricing/details/api-management/)
- [Bastion Entra sign-in](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication)
- [Bastion pricing](https://azure.microsoft.com/pricing/details/azure-bastion/)

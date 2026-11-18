[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.CognitiveServices/accounts/[^/]+$')]
    [string]$AccountId,
    [Parameter(Mandatory)][string]$VaultName,
    [Parameter(Mandatory)][string]$PublicCaPem,
    [string]$SecretName = 'ado-repro-ca'
)

$ErrorActionPreference = 'Stop'

function AzJson([string[]]$Arguments) {
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0]) $($Arguments[1])" }
    ($output -join "`n") | ConvertFrom-Json -Depth 100
}

$pemPath = (Resolve-Path -LiteralPath $PublicCaPem).Path
$pem = [IO.File]::ReadAllText($pemPath)
if ($pem -match 'PRIVATE KEY|PKCS12') { throw 'Supply public CA certificates only, never a private key or PFX.' }
$blocks = [regex]::Matches($pem, '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----')
if ($blocks.Count -eq 0) { throw 'No PEM certificates found.' }
foreach ($block in $blocks) {
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($block.Value)
    try {
        $constraints = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
        if ($constraints.Count -ne 1 -or -not $constraints[0].CertificateAuthority) {
            throw 'The PEM must contain CA certificates, not gateway leaf certificates.'
        }
        if ($cert.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow -or
            $cert.NotAfter.ToUniversalTime() -le [datetime]::UtcNow) {
            throw 'A CA certificate is expired or not yet valid.'
        }
    } finally { $cert.Dispose() }
}

$subscriptionId = $AccountId.Split('/')[2]
$apiVersion = '2026-07-15-preview'
$account = AzJson @('resource','show','--ids',$AccountId,'--api-version',$apiVersion,'-o','json')
$vault = AzJson @('keyvault','show','--subscription',$subscriptionId,'--name',$VaultName,'-o','json')
$sources = @($account.properties.trustedCertificateSources | Where-Object { $null -ne $_ })
if ($sources.Count -gt 1 -or ($sources.Count -eq 1 -and
    ($sources[0].type -ne 'AzureKeyVault' -or $sources[0].resourceId -ne $vault.id))) {
    throw 'Existing trust uses another source/vault. Refusing to replace it.'
}
$references = if ($sources.Count) { @($sources[0].certificateBundleReferences) } else { @() }
if (@($references | Where-Object secretName -NE $SecretName).Count -ge 25) {
    throw 'The account already has the maximum number of secret references.'
}
if (-not $PSCmdlet.ShouldProcess($AccountId, 'Upload public CA and merge its pinned trust reference')) { return }

$secretId = AzJson @(
    'keyvault','secret','set','--subscription',$subscriptionId,'--vault-name',$VaultName,
    '--name',$SecretName,'--file',$pemPath,'--encoding','utf-8',
    '--content-type','application/x-pem-file','--query','id','-o','json'
)
$version = ([uri]$secretId).AbsolutePath.TrimEnd('/').Split('/')[-1]
$references = @($references | Where-Object secretName -NE $SecretName) +
    @(@{ secretName = $SecretName; secretVersion = $version })
$body = @{
    properties = @{
        trustedCertificateSources = @(@{
            type = 'AzureKeyVault'
            resourceId = $vault.id
            certificateBundleReferences = $references
        })
    }
}
$temporaryFile = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($temporaryFile, ($body | ConvertTo-Json -Depth 20))
    & az rest --method patch `
        --url "https://management.azure.com${AccountId}?api-version=$apiVersion" `
        --body "@$temporaryFile" --output none
    if ($LASTEXITCODE -ne 0) { throw 'Trust update failed. The new public CA secret version exists but is not confirmed active.' }
} finally {
    Remove-Item -LiteralPath $temporaryFile -Force
}
Write-Host "Submitted the pinned trust reference for $SecretName. Allow propagation and rerun the tool test."

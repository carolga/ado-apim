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
$token = $null
$headers = $null
try {
    $token = & az account get-access-token --subscription $subscriptionId `
        --resource 'https://management.azure.com/' --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire an ARM access token.' }
    $headers = @{ Authorization = "Bearer $token" }
    $response = Invoke-WebRequest -Method Patch `
        -Uri "https://management.azure.com${AccountId}?api-version=$apiVersion" `
        -Headers $headers -ContentType 'application/json' `
        -Body ($body | ConvertTo-Json -Depth 20 -Compress) -SkipHttpErrorCheck
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Trust update failed (HTTP $($response.StatusCode))."
    }
    if ($response.StatusCode -eq 202) {
        $operationUrl = @($response.Headers['Azure-AsyncOperation'])[0]
        if (-not $operationUrl) { $operationUrl = @($response.Headers['Location'])[0] }
        $operationUri = $null
        if (-not [uri]::TryCreate($operationUrl, [UriKind]::Absolute, [ref]$operationUri) -or
            $operationUri.Scheme -ne 'https' -or $operationUri.Host -ne 'management.azure.com') {
            throw 'The trust update is pending, but ARM did not return a valid operation URL.'
        }
        $completed = $false
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $operation = Invoke-WebRequest -Method Get -Uri $operationUri.AbsoluteUri `
                -Headers $headers -SkipHttpErrorCheck
            if ($operation.StatusCode -lt 200 -or $operation.StatusCode -ge 300) {
                throw "Could not check the trust update (HTTP $($operation.StatusCode))."
            }
            $operationBody = $operation.Content | ConvertFrom-Json
            $status = $operationBody.status
            if (-not $status) { $status = $operationBody.properties.provisioningState }
            if ($status -eq 'Succeeded') { $completed = $true; break }
            if ($status -in @('Failed', 'Canceled')) { throw "Trust update ended with status $status." }
            Start-Sleep -Seconds 5
        }
        if (-not $completed) { throw 'Trust update is still pending after the monitoring window.' }
    }
    $updated = AzJson @('resource','show','--ids',$AccountId,'--api-version',$apiVersion,'-o','json')
    $confirmed = @($updated.properties.trustedCertificateSources | Where-Object {
        $_.type -eq 'AzureKeyVault' -and $_.resourceId -eq $vault.id
    } | ForEach-Object { $_.certificateBundleReferences } | Where-Object {
        $_.secretName -eq $SecretName -and $_.secretVersion -eq $version
    })
    if ($confirmed.Count -ne 1) { throw 'The version-pinned trust reference was not observed on the account.' }
    $updatedReferences = @($updated.properties.trustedCertificateSources |
        Where-Object { $_.type -eq 'AzureKeyVault' -and $_.resourceId -eq $vault.id } |
        ForEach-Object { $_.certificateBundleReferences })
    foreach ($reference in $references) {
        if (@($updatedReferences | Where-Object {
            $_.secretName -eq $reference.secretName -and $_.secretVersion -eq $reference.secretVersion
        }).Count -ne 1) {
            throw 'An expected existing CA reference was not observed after the update.'
        }
    }
} catch {
    throw "CA trust was not confirmed. The new public CA secret version may exist. $($_.Exception.Message)"
} finally {
    Remove-Variable token,headers -ErrorAction SilentlyContinue
}
Write-Host "Confirmed the pinned trust reference for $SecretName. Allow propagation and rerun the tool test."

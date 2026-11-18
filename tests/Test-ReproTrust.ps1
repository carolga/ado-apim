[CmdletBinding()]
param([Parameter(Mandatory)][string]$PublicCaPem)

$ErrorActionPreference = 'Stop'
$accountId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.CognitiveServices/accounts/test'
$vaultId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test'
$state = [pscustomobject]@{ CapturedBody = $null; Uploaded = $false; SourceVaultId = $vaultId }

# Function shadowing ensures this test never contacts Azure.
function global:az {
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'resource' {
            @{
                properties = @{
                    trustedCertificateSources = @(@{
                        type = 'AzureKeyVault'
                        resourceId = $state.SourceVaultId
                        certificateBundleReferences = @(
                            @{ secretName = 'keep-me'; secretVersion = 'existing-version' },
                            @{ secretName = 'ado-repro-ca'; secretVersion = 'old-version' }
                        )
                    })
                }
            } | ConvertTo-Json -Depth 20
        }
        'keyvault' {
            if ($args[1] -eq 'show') {
                @{ id = $vaultId } | ConvertTo-Json
            } elseif ($args[1] -eq 'secret' -and $args[2] -eq 'set') {
                $state.Uploaded = $true
                '"https://test.vault.azure.net/secrets/ado-repro-ca/new-version"'
            } else { throw 'Unexpected Key Vault invocation.' }
        }
        'rest' {
            $index = [array]::IndexOf($args, '--body')
            if ($index -lt 0) { throw 'Missing request body.' }
            $state.CapturedBody = Get-Content -LiteralPath $args[$index + 1].Substring(1) -Raw | ConvertFrom-Json
        }
        default { throw "Unexpected Azure command: $($args[0])" }
    }
}

try {
    $scriptPath = Join-Path $PSScriptRoot '..\scripts\repro\Set-FoundryCaTrust.ps1'
    & $scriptPath -AccountId $accountId -VaultName test -PublicCaPem $PublicCaPem -WhatIf
    if ($state.Uploaded -or $null -ne $state.CapturedBody) { throw 'WhatIf performed a write.' }
    & $scriptPath -AccountId $accountId -VaultName test -PublicCaPem $PublicCaPem -Confirm:$false
    if (-not $state.Uploaded -or $null -eq $state.CapturedBody) { throw 'Expected mocked trust update.' }
    $sources = @($state.CapturedBody.properties.trustedCertificateSources)
    $references = @($sources[0].certificateBundleReferences)
    if ($sources.Count -ne 1 -or $references.Count -ne 2) { throw 'Trust merge changed source/reference count.' }
    if (($references | Where-Object secretName -EQ 'keep-me').secretVersion -ne 'existing-version') {
        throw 'An unrelated reference was lost.'
    }
    if (($references | Where-Object secretName -EQ 'ado-repro-ca').secretVersion -ne 'new-version') {
        throw 'The target secret version was not replaced.'
    }
    $state.SourceVaultId = "$vaultId-other"
    $state.Uploaded = $false
    $state.CapturedBody = $null
    $rejected = $false
    try {
        & $scriptPath -AccountId $accountId -VaultName test -PublicCaPem $PublicCaPem -Confirm:$false
    } catch {
        if ($_.Exception.Message -notlike '*another source/vault*') { throw }
        $rejected = $true
    }
    if (-not $rejected -or $state.Uploaded -or $null -ne $state.CapturedBody) {
        throw 'A different vault was not safely rejected before writes.'
    }
    Write-Host 'Trust merge, WhatIf, and different-vault rejection passed without contacting Azure.'
} finally {
    Remove-Item Function:\global:az
}

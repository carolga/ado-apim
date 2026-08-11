[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Passes = 0
$script:Failures = 0

function Pass([string]$Message) { $script:Passes++; Write-Host "[PASS] $Message" -ForegroundColor Green }
function Fail([string]$Message) { $script:Failures++; Write-Host "[FAIL] $Message" -ForegroundColor Red }
function Rel([string]$Path) { [IO.Path]::GetRelativePath($repoRoot, $Path) }
function Text([string]$Path) { [IO.File]::ReadAllText($Path) }

function Required([string]$RelativePath) {
    $path = Join-Path $repoRoot $RelativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) { Pass "$RelativePath exists"; return $path }
    Fail "$RelativePath is missing"
    return $null
}

function Has([string]$Content, [string]$Pattern, [string]$Message) {
    if ($Content -match $Pattern) { Pass $Message } else { Fail $Message }
}

function Lacks([string]$Content, [string]$Pattern, [string]$Message) {
    if ($Content -match $Pattern) { Fail $Message } else { Pass $Message }
}

function Run([string]$File, [string[]]$Arguments, [string]$Message) {
    & $File @Arguments
    if ($LASTEXITCODE -eq 0) { Pass $Message; return }
    Fail "$Message (exit $LASTEXITCODE)"
}

function Parse-PowerShell([string]$Path) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) { Pass "$(Rel $Path) parses as PowerShell" }
    else { Fail "$(Rel $Path) PowerShell parse errors: $($errors.Message -join '; ')" }
}

function Get-SourceHygieneIssues([byte[]]$Bytes, [string]$DisplayName) {
    $issues = [Collections.Generic.List[string]]::new()
    try {
        $content = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    } catch {
        $issues.Add("$DisplayName is not valid UTF-8")
        return @($issues)
    }
    if ($content.IndexOf([char]0) -ge 0) { $issues.Add("$DisplayName contains a NUL byte") }
    if ($content -match '(?m)[\t ]+(?=\r?$)') { $issues.Add("$DisplayName contains trailing whitespace") }
    if ($content -match '(?m)^(?:<{7}(?: .*)?|={7}|>{7}(?: .*)?)\r?$') { $issues.Add("$DisplayName contains a merge-conflict marker") }
    if ($content -match "`r(?!`n)") { $issues.Add("$DisplayName contains a bare carriage return") }
    if ($content.Contains("`r`n") -and $content -match "(?<!`r)`n") { $issues.Add("$DisplayName mixes CRLF and LF newlines") }
    @($issues)
}

Push-Location $repoRoot
try {
    Write-Host 'Azure DevOps hosted MCP through APIM validation' -ForegroundColor Cyan

    Required 'README.md' | Out-Null
    Required 'azure.yaml' | Out-Null
    Required 'infra\main.bicep' | Out-Null
    Required 'infra\modules\apim.bicep' | Out-Null
    Required 'infra\modules\apim-apis.bicep' | Out-Null
    Required 'infra\modules\observability.bicep' | Out-Null
    Required 'infra\policies\ado-remote-mcp-policy.xml' | Out-Null

    foreach ($json in Get-ChildItem $repoRoot -Recurse -File -Filter '*.json' |
        Where-Object FullName -notmatch '\\(?:\.git|\.github|\.azure|\.copilot|\.squad|bin|obj)\\') {
        try { Text $json.FullName | ConvertFrom-Json -Depth 100 | Out-Null; Pass "$(Rel $json.FullName) parses as JSON" }
        catch { Fail "$(Rel $json.FullName) JSON parse error: $($_.Exception.Message)" }
    }
    foreach ($xml in Get-ChildItem $repoRoot -Recurse -File -Filter '*.xml' |
        Where-Object FullName -notmatch '\\(?:\.git|\.github|\.azure|\.copilot|\.squad|bin|obj)\\') {
        try { [xml](Text $xml.FullName) | Out-Null; Pass "$(Rel $xml.FullName) parses as XML" }
        catch { Fail "$(Rel $xml.FullName) XML parse error: $($_.Exception.Message)" }
    }
    foreach ($ps1 in Get-ChildItem $repoRoot -Recurse -File -Filter '*.ps1' |
        Where-Object FullName -notmatch '\\(?:\.git|\.github|\.azure|\.copilot|\.squad|bin|obj)\\') { Parse-PowerShell $ps1.FullName }

    $az = Get-Command az -ErrorAction SilentlyContinue
    if ($az) {
        foreach ($file in Get-ChildItem (Join-Path $repoRoot 'infra') -Recurse -File -Filter '*.bicep') {
            $output = Join-Path $repoRoot "tests\.generated-$($file.BaseName).json"
            try { Run $az.Source @('bicep','build','--file',$file.FullName,'--outfile',$output) "$(Rel $file.FullName) compiles as Bicep" }
            finally { Remove-Item $output -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Fail 'Azure CLI is required for Bicep compilation'
    }

    $files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force |
        Where-Object FullName -notmatch '\\(?:\.git|\.github|\.azure|\.copilot|\.squad|artifacts|bin|obj|node_modules)\\' |
        Where-Object { $_.Extension -in @('.bicep','.json','.md','.ps1','.xml','.yaml','.yml') -or $_.Name -in @('.gitattributes','.gitignore') }
    $issues = @($files | ForEach-Object { Get-SourceHygieneIssues ([IO.File]::ReadAllBytes($_.FullName)) (Rel $_.FullName) })
    if ($issues.Count -eq 0) { Pass "repository source hygiene passes direct scan ($($files.Count) files)" }
    else { Fail "repository source hygiene failed: $($issues -join '; ')" }

    $implementationText = (Get-ChildItem $repoRoot -Recurse -File |
        Where-Object FullName -notmatch '\\(?:\.git|\.github|\.azure|\.copilot|\.squad|tests|bin|obj)\\' |
        Where-Object Extension -in @('.bicep','.json','.md','.ps1','.xml','.yaml','.yml') |
        ForEach-Object { Text $_.FullName }) -join "`n"

    Has $implementationText 'https://mcp\.dev\.azure\.com' 'implementation targets hosted Azure DevOps MCP'
    Has $implementationText 'ado-remote-mcp-proxy' 'implementation exposes the APIM proxy path'
    Has $implementationText 'WWW-Authenticate' 'documentation describes hosted ADO MCP auth challenge handling'
    Has $implementationText 'X-MCP-Readonly' 'policy enforces hosted ADO MCP read-only header'
    Has $implementationText 'X-MCP-Toolsets' 'policy enforces hosted ADO MCP toolsets header'
    Has $implementationText '(?im)body\s*:\s*\{\s*bytes\s*:\s*0' 'diagnostics log zero body bytes'
    Lacks $implementationText '(?i)(AdoMcpBroker|AcquireTokenOnBehalfOf|MCP_Access|vso\.|apim-obo|AcrPull|REST-to-MCP)' 'implementation contains no removed architecture references'
    Lacks $implementationText '(?i)(client_secret|passwordCredentials)' 'implementation contains no credential fallback references'
}
finally {
    Pop-Location
}

Write-Host "`nResult: $script:Passes passed, $script:Failures failed" -ForegroundColor Cyan
if ($script:Failures -gt 0) { exit 1 }

param([string] $UpdaterPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($UpdaterPath)) {
    $UpdaterPath = Join-Path $repoRoot 'update.ps1'
}
$source = Get-Content -LiteralPath $UpdaterPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    ([System.IO.Path]::GetFullPath($UpdaterPath)),
    [ref] $tokens,
    [ref] $parseErrors
)
if (@($parseErrors).Count -gt 0) { throw "Updater parse failed: $($parseErrors[0].Message)" }

function Get-UpdaterFunctionText {
    param([Parameter(Mandatory = $true)][string] $Name)

    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $Name
    }, $true)
    if ($null -eq $functionAst) { throw "$Name was not found in the updater." }
    return $functionAst.Extent.Text
}

foreach ($name in @(
    'Test-SafePublicUpdateIpv4Address',
    'Test-UpdateDnsFailure',
    'ConvertTo-CurlConfigValue'
)) {
    Invoke-Expression (Get-UpdaterFunctionText -Name $name)
}

if (-not (Test-SafePublicUpdateIpv4Address -Value '75.119.136.143')) {
    throw 'The updater rejected the known public live address.'
}
foreach ($unsafe in @('127.0.0.1', '10.0.0.1', '169.254.1.1', '172.16.0.1', '192.168.1.1', '224.0.0.1', 'not-an-ip')) {
    if (Test-SafePublicUpdateIpv4Address -Value $unsafe) {
        throw "The updater accepted unsafe fallback address $unsafe."
    }
}

$dnsFailure = $false
try {
    throw [System.Net.WebException]::new("The remote name could not be resolved: 'sync.velvet-leaf.com'")
}
catch {
    $dnsFailure = Test-UpdateDnsFailure -ErrorRecord $_
}
if (-not $dnsFailure) { throw 'The updater did not classify the production DNS failure for fallback.' }

$ordinaryFailure = $false
try {
    throw [System.Net.WebException]::new('The remote server returned an error: (403) Forbidden.')
}
catch {
    $ordinaryFailure = Test-UpdateDnsFailure -ErrorRecord $_
}
if ($ordinaryFailure) { throw 'The updater incorrectly routed a permanent HTTP failure through DNS fallback.' }

foreach ($required in @(
    "`$script:TrustedUpdateHost = 'sync.velvet-leaf.com'",
    "'cloudflare-dns.com'",
    "'1.1.1.1'",
    "'dns.google'",
    "'8.8.8.8'",
    "'--resolve'",
    "'--retry-all-errors'",
    "'continue-at = `"-`"'",
    'Test-InstalledFileMatchesManifest -Path $partialFile',
    'Secure DNS fallback completed but the payload failed size or SHA-256 verification.'
)) {
    if (-not $source.Contains($required)) { throw "Updater DNS fallback contract is missing: $required" }
}
foreach ($forbidden in @('--insecure', '-k ', 'ServerCertificateValidationCallback', 'CertificatePolicy')) {
    if ($source.Contains($forbidden)) { throw "Updater DNS fallback weakens TLS verification with: $forbidden" }
}

$escaped = ConvertTo-CurlConfigValue -Value 'C:\Folder With Space\payload"name.part'
if ($escaped -ne 'C:\\Folder With Space\\payload\"name.part') {
    throw "curl config escaping is unsafe: $escaped"
}

Write-Host 'PASS updater uses bounded verified-IP DNS fallback without weakening HTTPS or payload verification.'

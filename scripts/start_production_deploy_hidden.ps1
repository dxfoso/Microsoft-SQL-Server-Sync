[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Commit,
    [string] $LogDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Commit -notmatch '^[0-9a-f]{40}$') {
    throw 'Commit must be an exact 40-character lowercase Git SHA.'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path $repoRoot 'artifacts/deployment-logs'
}
$LogDirectory = [IO.Path]::GetFullPath($LogDirectory)
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$stdout = Join-Path $LogDirectory "deploy-$stamp-$suffix.out.log"
$stderr = Join-Path $LogDirectory "deploy-$stamp-$suffix.err.log"
$deployScript = Join-Path $PSScriptRoot 'deploy_production_images.ps1'
$arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', "`"$deployScript`"",
    '-Commit', $Commit
)

$process = Start-Process `
    -FilePath 'powershell.exe' `
    -ArgumentList $arguments `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru

[pscustomobject]@{
    processId = $process.Id
    stdout = $stdout
    stderr = $stderr
} | ConvertTo-Json -Compress

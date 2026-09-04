[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SourceClient,
    [Parameter(Mandatory = $true)][string] $TargetClient,
    [string] $Database = 'AmnDb048',
    [ValidateRange(10, 1440)][int] $TimeoutMinutes = 360,
    [switch] $ReuseCompletedSourceBackup,
    [string] $LogPrefix = 'database-clone'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cloneScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'clone_live_client_database.ps1'))
foreach ($value in @($SourceClient, $TargetClient, $Database, $LogPrefix)) {
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('"') -or $value.Contains("`r") -or $value.Contains("`n")) {
        throw 'Clone launcher values must be non-empty single-line text without quote characters.'
    }
}
$safeLogPrefix = $LogPrefix -replace '[^A-Za-z0-9._-]', '_'
$stdoutPath = Join-Path $repoRoot "$safeLogPrefix.stdout.log"
$stderrPath = Join-Path $repoRoot "$safeLogPrefix.stderr.log"
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SourceClient "{1}" -TargetClient "{2}" -Database "{3}" -TimeoutMinutes {4}' -f `
    $cloneScript, $SourceClient, $TargetClient, $Database, $TimeoutMinutes
if ($ReuseCompletedSourceBackup) {
    $arguments += ' -ReuseCompletedSourceBackup'
}
$process = Start-Process `
    -FilePath 'powershell.exe' `
    -ArgumentList $arguments `
    -WorkingDirectory $repoRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru
[pscustomobject]@{
    Pid = $process.Id
    Stdout = $stdoutPath
    Stderr = $stderrPath
} | ConvertTo-Json -Compress

[CmdletBinding()]
param(
    [string] $SourceClient = 'velvet factory',
    [string] $SourceDatabase = 'AmnDb048',
    [string] $LabDatabase = 'AmnDb048_SyncLab',
    [ValidateRange(10, 1440)][int] $TimeoutMinutes = 360,
    [string] $LogPrefix = 'alameen-sync-lab'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'provision_alameen_sync_lab.ps1'))
foreach ($value in @($SourceClient, $SourceDatabase, $LabDatabase, $LogPrefix)) {
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('"') -or $value.Contains("`r") -or $value.Contains("`n")) {
        throw 'Launcher values must be non-empty single-line text without quote characters.'
    }
}
$safePrefix = $LogPrefix -replace '[^A-Za-z0-9._-]', '_'
$stdoutPath = Join-Path $repoRoot "$safePrefix.stdout.log"
$stderrPath = Join-Path $repoRoot "$safePrefix.stderr.log"
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SourceClient "{1}" -SourceDatabase "{2}" -LabDatabase "{3}" -TimeoutMinutes {4}' -f `
    $scriptPath, $SourceClient, $SourceDatabase, $LabDatabase, $TimeoutMinutes
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
    -WorkingDirectory $repoRoot -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
[pscustomobject]@{ Pid = $process.Id; Stdout = $stdoutPath; Stderr = $stderrPath } | ConvertTo-Json -Compress

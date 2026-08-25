param(
    [string] $ManifestUrl = 'https://sync.velvet-leaf.com/client/latest.json',
    [string] $InstallDir = '',
    [string] $ExpectedVersion = '',
    [int] $LauncherSupervisorProcessId = 0,
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    throw 'InstallDir is required.'
}

$resolvedInstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$localUpdater = Join-Path -Path $resolvedInstallDir -ChildPath 'update.ps1'
if (-not (Test-Path -LiteralPath $localUpdater -PathType Leaf)) {
    throw "The packaged resumable updater is missing: $localUpdater"
}

$invokeParameters = @{
    ManifestUrl = $ManifestUrl
    InstallDir = $resolvedInstallDir
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $invokeParameters.ExpectedVersion = $ExpectedVersion
}
if ($LauncherSupervisorProcessId -gt 0) {
    $invokeParameters.LauncherSupervisorProcessId = $LauncherSupervisorProcessId
}
if ($NoStart) {
    $invokeParameters.NoStart = $true
}

& $localUpdater @invokeParameters

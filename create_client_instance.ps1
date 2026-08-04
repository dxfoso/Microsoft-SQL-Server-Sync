param(
    [Parameter(Mandatory = $true)][string] $InstanceId,
    [string] $DisplayName = '',
    [string] $Server = '',
    [string] $Database = '',
    [string] $SourceInstallDir = $PSScriptRoot,
    [string] $InstancesRoot = '',
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$normalizedId = $InstanceId.Trim().ToLowerInvariant()
if ($normalizedId -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') {
    throw 'InstanceId must use 1-32 lowercase letters, numbers, or hyphens.'
}

$source = [System.IO.Path]::GetFullPath($SourceInstallDir)
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Source client installation does not exist: $source"
}
if (-not (Test-Path -LiteralPath (Join-Path $source 'sync_windows_agent.exe') -PathType Leaf)) {
    throw "Source client executable is missing: $source"
}

if ([string]::IsNullOrWhiteSpace($InstancesRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; specify -InstancesRoot.'
    }
    $InstancesRoot = Join-Path $env:LOCALAPPDATA 'Microsoft-SQL-Server-Sync\instances'
}
$root = [System.IO.Path]::GetFullPath($InstancesRoot).TrimEnd('\', '/')
$target = [System.IO.Path]::GetFullPath((Join-Path $root $normalizedId))
$requiredPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
if (-not $target.StartsWith($requiredPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Resolved instance directory is outside InstancesRoot.'
}
if (Test-Path -LiteralPath $target) {
    throw "Client instance already exists: $target"
}

New-Item -Path $root -ItemType Directory -Force | Out-Null
New-Item -Path $target -ItemType Directory | Out-Null

$skipNames = @(
    'client-instance.json',
    'sync_windows_agent_startup.log',
    'sync_windows_agent_supervisor.log',
    'sync_windows_agent_update.log',
    'sync_windows_agent_update_requests.log'
)
foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
    if ($skipNames -contains $item.Name) {
        continue
    }
    Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
}

$instanceLabel = if ([string]::IsNullOrWhiteSpace($DisplayName)) { $normalizedId } else { $DisplayName.Trim() }
$instanceConfig = [ordered]@{
    version = 1
    id = $normalizedId
    displayName = $instanceLabel
}
$instanceConfig | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'client-instance.json') -Encoding UTF8

$profileRoot = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
    $env:APPDATA
} elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $env:LOCALAPPDATA
} else {
    throw 'APPDATA and LOCALAPPDATA are unavailable.'
}
$stateRoot = Join-Path $profileRoot 'Microsoft-SQL-Server-Sync'
$sourceState = Join-Path $stateRoot 'sync_windows_agent_state.json'
$targetStateDir = Join-Path (Join-Path $stateRoot 'instances') $normalizedId
$targetState = Join-Path $targetStateDir 'sync_windows_agent_state.json'
New-Item -Path $targetStateDir -ItemType Directory -Force | Out-Null

if (Test-Path -LiteralPath $sourceState -PathType Leaf) {
    $state = Get-Content -LiteralPath $sourceState -Raw | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace($Server)) {
        $state.server = $Server.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        if ($null -eq $state.selectedDatabasesByUser) {
            $state | Add-Member -NotePropertyName selectedDatabasesByUser -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $keys = @($state.accountUsername, $state.accountEmail, $state.accountName, $state.rememberedLoginName) |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
            Select-Object -Unique
        foreach ($key in $keys) {
            $state.selectedDatabasesByUser | Add-Member -NotePropertyName $key -NotePropertyValue $Database.Trim() -Force
        }
    }
    $state | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $targetState -Encoding UTF8
}

if (-not $NoStart) {
    $supervisor = Join-Path $target 'sync_windows_agent_supervisor.ps1'
    if (-not (Test-Path -LiteralPath $supervisor -PathType Leaf)) {
        throw "Client supervisor is missing: $supervisor"
    }
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $supervisor)) `
        -WorkingDirectory $target `
        -WindowStyle Hidden | Out-Null
}

[pscustomobject]@{
    InstanceId = $normalizedId
    DisplayName = $instanceLabel
    InstallDirectory = $target
    StateFile = $targetState
    Server = $Server.Trim()
    Database = $Database.Trim()
    Started = -not $NoStart
}

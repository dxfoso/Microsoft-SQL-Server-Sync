param(
    [string] $ManifestUrl = 'https://sync.velvet-leaf.com/client/latest.json',
    [string] $InstallDir = '',
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-UpdateUrl {
    param(
        [Parameter(Mandatory = $true)][string] $BaseUrl,
        [Parameter(Mandatory = $true)][string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'Update manifest is missing the zipUrl value.'
    }

    $uri = [System.Uri]::new($Value, [System.UriKind]::RelativeOrAbsolute)
    if ($uri.IsAbsoluteUri) {
        return $uri.AbsoluteUri
    }

    return ([System.Uri]::new([System.Uri]::new($BaseUrl), $Value)).AbsoluteUri
}

function Get-DefaultInstallDir {
    $portableExe = Join-Path -Path $PSScriptRoot -ChildPath 'sync_windows_agent.exe'
    if (Test-Path -LiteralPath $portableExe -PathType Leaf) {
        return $PSScriptRoot
    }

    return Join-Path -Path $env:LOCALAPPDATA -ChildPath 'MicrosoftSqlServerSync\sync_windows_agent'
}

function Stop-AgentProcesses {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $targetFull = [System.IO.Path]::GetFullPath($TargetInstallDir).TrimEnd('\', '/')
    $targetPrefix = $targetFull + [System.IO.Path]::DirectorySeparatorChar

    Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            if ([string]::IsNullOrWhiteSpace($_.ExecutablePath)) {
                return $false
            }
            $exePath = [System.IO.Path]::GetFullPath($_.ExecutablePath)
            return $exePath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        ForEach-Object {
            Write-Host "Stopping sync_windows_agent.exe [$($_.ProcessId)]"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Get-SingleChildDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    $children = @(Get-ChildItem -LiteralPath $Path -Directory -Force)
    if ($children.Count -eq 1) {
        return $children[0].FullName
    }

    return $Path
}

function Start-DeferredInstall {
    param(
        [Parameter(Mandatory = $true)][string] $PayloadDir,
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][int] $ParentProcessId,
        [string] $Version = '',
        [switch] $NoStart
    )

    $helperPath = Join-Path -Path $WorkRoot -ChildPath 'finalize-update.ps1'
    $helper = @'
param(
    [Parameter(Mandatory = $true)][string] $PayloadDir,
    [Parameter(Mandatory = $true)][string] $InstallDir,
    [Parameter(Mandatory = $true)][string] $WorkRoot,
    [Parameter(Mandatory = $true)][int] $ParentProcessId,
    [string] $Version = '',
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

for ($attempt = 0; $attempt -lt 120; $attempt++) {
    $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($null -eq $parent) {
        break
    }
    Start-Sleep -Milliseconds 250
}

New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath $PayloadDir -Force |
    Copy-Item -Destination $InstallDir -Recurse -Force

$installedExe = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.exe'
if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    throw "Update completed but the installed executable is missing: $installedExe"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Host "Installed sync_windows_agent to $InstallDir"
} else {
    Write-Host "Installed sync_windows_agent version $Version to $InstallDir"
}

if (-not $NoStart) {
    $launcherPath = Join-Path -Path $InstallDir -ChildPath 'run_portable.bat'
    if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
        Start-Process -FilePath $launcherPath -WorkingDirectory $InstallDir
    } else {
        Start-Process -FilePath $installedExe -WorkingDirectory $InstallDir
    }
}

Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
'@

    Set-Content -LiteralPath $helperPath -Value $helper -Encoding ASCII

    $startArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $helperPath,
        '-PayloadDir', $PayloadDir,
        '-InstallDir', $TargetInstallDir,
        '-WorkRoot', $WorkRoot,
        '-ParentProcessId', $ParentProcessId
    )
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $startArgs += @('-Version', $Version)
    }
    if ($NoStart) {
        $startArgs += '-NoStart'
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $startArgs -WorkingDirectory $WorkRoot -WindowStyle Hidden
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Get-DefaultInstallDir
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
Write-Host "Reading update manifest: $ManifestUrl"
$manifest = Invoke-RestMethod -UseBasicParsing -Uri $ManifestUrl
$zipValue = if (-not [string]::IsNullOrWhiteSpace([string] $manifest.latestZipUrl)) {
    [string] $manifest.latestZipUrl
} else {
    [string] $manifest.zipUrl
}
$zipUrl = Resolve-UpdateUrl -BaseUrl $ManifestUrl -Value $zipValue

$workRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("sync-windows-agent-update-{0}" -f ([guid]::NewGuid().ToString('N')))
$zipPath = Join-Path -Path $workRoot -ChildPath 'sync_windows_agent.zip'
$extractDir = Join-Path -Path $workRoot -ChildPath 'extract'

New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
try {
    Write-Host "Downloading client package: $zipUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zipPath

    $expectedHash = [string] $manifest.sha256
    if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
            throw "Downloaded package hash mismatch. Expected $expectedHash but got $actualHash."
        }
    }

    New-Item -Path $extractDir -ItemType Directory -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $payloadDir = Get-SingleChildDirectory -Path $extractDir
    $payloadExe = Join-Path -Path $payloadDir -ChildPath 'sync_windows_agent.exe'
    if (-not (Test-Path -LiteralPath $payloadExe -PathType Leaf)) {
        throw "Downloaded package does not contain sync_windows_agent.exe at the expected path: $payloadExe"
    }

    Stop-AgentProcesses -TargetInstallDir $InstallDir
    Start-DeferredInstall `
        -PayloadDir $payloadDir `
        -TargetInstallDir $InstallDir `
        -WorkRoot $workRoot `
        -ParentProcessId $PID `
        -Version ([string] $manifest.version) `
        -NoStart:$NoStart
    Write-Host "Updating sync_windows_agent version $($manifest.version) in $InstallDir"
}
finally {
    if (-not (Test-Path -LiteralPath (Join-Path -Path $workRoot -ChildPath 'finalize-update.ps1') -PathType Leaf)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

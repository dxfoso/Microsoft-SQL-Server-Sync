param(
    [string] $ManifestUrl = 'https://sync.velvet-leaf.com/client/latest.json',
    [string] $InstallDir = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'MicrosoftSqlServerSync\sync_windows_agent'),
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

Write-Host "Reading update manifest: $ManifestUrl"
$manifest = Invoke-RestMethod -UseBasicParsing -Uri $ManifestUrl
$zipUrl = Resolve-UpdateUrl -BaseUrl $ManifestUrl -Value ([string] $manifest.zipUrl)

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
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    Get-ChildItem -LiteralPath $payloadDir -Force |
        Copy-Item -Destination $InstallDir -Recurse -Force

    $installedExe = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.exe'
    if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
        throw "Update completed but the installed executable is missing: $installedExe"
    }

    Write-Host "Installed sync_windows_agent version $($manifest.version) to $InstallDir"
    if (-not $NoStart) {
        Start-Process -FilePath $installedExe -WorkingDirectory $InstallDir
        Write-Host 'Started sync_windows_agent.exe'
    }
}
finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

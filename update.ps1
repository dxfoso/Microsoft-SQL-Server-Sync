param(
    [string] $ManifestUrl = 'https://sync.velvet-leaf.com/client/latest.json',
    [string] $InstallDir = '',
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-UpdateLog {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [string] $LogPath = ''
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    $line = "[$timestamp] $Message"
    Write-Host $line

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        return
    }

    $logDir = Split-Path -Path $LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding ASCII
}

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

function Initialize-NetworkSecurityProtocol {
    try {
        $flags = [System.Net.SecurityProtocolType]::Tls12
        if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13') {
            $flags = $flags -bor [System.Net.SecurityProtocolType]::Tls13
        }
        [System.Net.ServicePointManager]::SecurityProtocol = $flags
    }
    catch {
        # Best effort. Older frameworks may not expose every flag.
    }
}

function New-UpdateWebClient {
    Initialize-NetworkSecurityProtocol
    $client = [System.Net.WebClient]::new()
    $client.Headers[[System.Net.HttpRequestHeader]::UserAgent] = 'SqlSyncAgentUpdater/1.0'
    return $client
}

function Invoke-UpdateRestMethod {
    param([Parameter(Mandatory = $true)][string] $Uri)

    $client = New-UpdateWebClient
    try {
        $content = $client.DownloadString($Uri)
        return $content | ConvertFrom-Json
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-UpdateWebRequest {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $OutFile
    )

    $client = New-UpdateWebClient
    try {
        $client.DownloadFile($Uri, $OutFile)
    }
    finally {
        $client.Dispose()
    }
}

function Get-DefaultInstallDir {
    $portableExe = Join-Path -Path $PSScriptRoot -ChildPath 'sync_windows_agent.exe'
    if (Test-Path -LiteralPath $portableExe -PathType Leaf) {
        return $PSScriptRoot
    }

    return Join-Path -Path $env:LOCALAPPDATA -ChildPath 'MicrosoftSqlServerSync\sync_windows_agent'
}

function Format-UpdateBytes {
    param([int64] $Value)

    if ($Value -lt 1KB) {
        return "$Value B"
    }

    $units = @('KB', 'MB', 'GB', 'TB')
    $size = [double] $Value
    $unitIndex = -1
    while ($size -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $size /= 1024
        $unitIndex += 1
    }

    if ($unitIndex -lt 0) {
        return "$Value B"
    }

    return ('{0:N1} {1}' -f $size, $units[$unitIndex])
}

function Get-UpdateDriveFreeBytes {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        if ([string]::IsNullOrWhiteSpace($root)) {
            return -1
        }

        $drive = [System.IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) {
            return -1
        }

        return [int64] $drive.AvailableFreeSpace
    }
    catch {
        return -1
    }
}

function Select-UpdateWorkParent {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [Parameter(Mandatory = $true)][int64] $RequiredBytes,
        [string] $LogPath = ''
    )

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    $seenCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in @(
        [System.IO.Path]::GetTempPath(),
        (Split-Path -Path $TargetInstallDir -Parent),
        [System.IO.Path]::GetPathRoot($TargetInstallDir)
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $normalized = [System.IO.Path]::GetFullPath($candidate)
        if ($seenCandidates.Add($normalized)) {
            [void] $candidatePaths.Add($normalized)
        }
    }

    $freeSpaceSummaries = [System.Collections.Generic.List[string]]::new()
    foreach ($candidatePath in $candidatePaths) {
        $availableBytes = Get-UpdateDriveFreeBytes -Path $candidatePath
        $availableLabel = if ($availableBytes -ge 0) {
            Format-UpdateBytes -Value $availableBytes
        } else {
            'unknown'
        }
        [void] $freeSpaceSummaries.Add("$candidatePath => $availableLabel")

        if ($availableBytes -ge $RequiredBytes) {
            $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
            if (-not $candidatePath.Equals($systemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-UpdateLog -Message "Using update staging path $candidatePath because system temp does not have enough free space for $(Format-UpdateBytes -Value $RequiredBytes)." -LogPath $LogPath
            }
            return $candidatePath
        }
    }

    $requiredLabel = Format-UpdateBytes -Value $RequiredBytes
    $summary = $freeSpaceSummaries -join '; '
    throw "Not enough free space for client update staging. Required at least $requiredLabel. Checked: $summary"
}

function Get-AgentProcesses {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $targetFull = [System.IO.Path]::GetFullPath($TargetInstallDir).TrimEnd('\', '/')
    $targetPrefix = $targetFull + [System.IO.Path]::DirectorySeparatorChar

    return @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            if ([string]::IsNullOrWhiteSpace($_.ExecutablePath)) {
                return $false
            }
            $exePath = [System.IO.Path]::GetFullPath($_.ExecutablePath)
            return $exePath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
}

function Stop-AgentProcesses {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [int] $MaxWaitSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $MaxWaitSeconds))
    do {
        $agentProcesses = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir)
        if (@($agentProcesses).Count -eq 0) {
            return
        }
        foreach ($process in $agentProcesses) {
            Write-Host "Stopping sync_windows_agent.exe [$($process.ProcessId)]"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir)
    if (@($remaining).Count -gt 0) {
        throw "Timed out waiting for sync_windows_agent.exe to exit from $TargetInstallDir"
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

function Get-AgentProcesses {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $targetFull = [System.IO.Path]::GetFullPath($TargetInstallDir).TrimEnd('\', '/')
    $targetPrefix = $targetFull + [System.IO.Path]::DirectorySeparatorChar

    return @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            if ([string]::IsNullOrWhiteSpace($_.ExecutablePath)) {
                return $false
            }
            $exePath = [System.IO.Path]::GetFullPath($_.ExecutablePath)
            return $exePath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
}

function Stop-AgentProcesses {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [int] $MaxWaitSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $MaxWaitSeconds))
    do {
        $agentProcesses = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir)
        if (@($agentProcesses).Count -eq 0) {
            return
        }
        foreach ($process in $agentProcesses) {
            Write-Host "Stopping sync_windows_agent.exe [$($process.ProcessId)]"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir)
    if (@($remaining).Count -gt 0) {
        throw "Timed out waiting for sync_windows_agent.exe to exit from $TargetInstallDir"
    }
}

function Write-UpdateLog {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    $line = "[$timestamp] $Message"
    Write-Host $line
    $logDir = Split-Path -Path $LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding ASCII
}

$logPath = Join-Path -Path $InstallDir -ChildPath 'update.log'
Write-UpdateLog -Message "Finalize update helper started. payload=$PayloadDir install=$InstallDir parent=$ParentProcessId" -LogPath $logPath

for ($attempt = 0; $attempt -lt 120; $attempt++) {
    $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($null -eq $parent) {
        Write-UpdateLog -Message "Parent process exited after $attempt wait iterations." -LogPath $logPath
        break
    }
    Start-Sleep -Milliseconds 250
}

Write-UpdateLog -Message "Ensuring prior client instances are stopped before install." -LogPath $logPath
Stop-AgentProcesses -TargetInstallDir $InstallDir

New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
Write-UpdateLog -Message "Copying payload into install dir." -LogPath $logPath
Get-ChildItem -LiteralPath $PayloadDir -Force |
    Copy-Item -Destination $InstallDir -Recurse -Force

$installedExe = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.exe'
if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    throw "Update completed but the installed executable is missing: $installedExe"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-UpdateLog -Message "Installed sync_windows_agent to $InstallDir" -LogPath $logPath
} else {
    Write-UpdateLog -Message "Installed sync_windows_agent version $Version to $InstallDir" -LogPath $logPath
}

if (-not $NoStart) {
    Write-UpdateLog -Message "Stopping any remaining client instances before relaunch." -LogPath $logPath
    Stop-AgentProcesses -TargetInstallDir $InstallDir
    Write-UpdateLog -Message "Starting updated client executable: $installedExe" -LogPath $logPath
    Start-Process -FilePath $installedExe -WorkingDirectory $InstallDir
} else {
    Write-UpdateLog -Message 'NoStart set. Skipping client relaunch.' -LogPath $logPath
}

Write-UpdateLog -Message "Finalize helper cleaning work root: $WorkRoot" -LogPath $logPath
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
$mainLogPath = Join-Path -Path $InstallDir -ChildPath 'update.log'
Write-UpdateLog -Message "Updater starting. manifest=$ManifestUrl install=$InstallDir noStart=$NoStart" -LogPath $mainLogPath
$manifest = Invoke-UpdateRestMethod -Uri $ManifestUrl
$zipValue = if (-not [string]::IsNullOrWhiteSpace([string] $manifest.latestZipUrl)) {
    [string] $manifest.latestZipUrl
} else {
    [string] $manifest.zipUrl
}
$zipUrl = Resolve-UpdateUrl -BaseUrl $ManifestUrl -Value $zipValue

$requiredFreeBytes = 512MB
try {
    $declaredSizeBytes = [int64] $manifest.sizeBytes
    if ($declaredSizeBytes -gt 0) {
        $requiredFreeBytes = [int64] [Math]::Max($requiredFreeBytes, $declaredSizeBytes * 4)
    }
}
catch {
    $requiredFreeBytes = 512MB
}

$workParent = Select-UpdateWorkParent -TargetInstallDir $InstallDir -RequiredBytes $requiredFreeBytes -LogPath $mainLogPath
$workRoot = Join-Path -Path $workParent -ChildPath ("sync-windows-agent-update-{0}" -f ([guid]::NewGuid().ToString('N')))
$zipPath = Join-Path -Path $workRoot -ChildPath 'sync_windows_agent.zip'
$extractDir = Join-Path -Path $workRoot -ChildPath 'extract'

New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
try {
    Write-UpdateLog -Message "Downloading client package: $zipUrl" -LogPath $mainLogPath
    Invoke-UpdateWebRequest -Uri $zipUrl -OutFile $zipPath

    $expectedHash = [string] $manifest.sha256
    if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
            throw "Downloaded package hash mismatch. Expected $expectedHash but got $actualHash."
        }
        Write-UpdateLog -Message "Package hash verified: $actualHash" -LogPath $mainLogPath
    }

    New-Item -Path $extractDir -ItemType Directory -Force | Out-Null
    Write-UpdateLog -Message "Expanding package into $extractDir" -LogPath $mainLogPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $payloadDir = Get-SingleChildDirectory -Path $extractDir
    $payloadExe = Join-Path -Path $payloadDir -ChildPath 'sync_windows_agent.exe'
    if (-not (Test-Path -LiteralPath $payloadExe -PathType Leaf)) {
        throw "Downloaded package does not contain sync_windows_agent.exe at the expected path: $payloadExe"
    }

    Stop-AgentProcesses -TargetInstallDir $InstallDir
    Write-UpdateLog -Message "Scheduling deferred install. payload=$payloadDir" -LogPath $mainLogPath
    Start-DeferredInstall `
        -PayloadDir $payloadDir `
        -TargetInstallDir $InstallDir `
        -WorkRoot $workRoot `
        -ParentProcessId $PID `
        -Version ([string] $manifest.version) `
        -NoStart:$NoStart
    Write-UpdateLog -Message "Updater scheduled for version $($manifest.version) in $InstallDir" -LogPath $mainLogPath
}
finally {
    if (-not (Test-Path -LiteralPath (Join-Path -Path $workRoot -ChildPath 'finalize-update.ps1') -PathType Leaf)) {
        Write-UpdateLog -Message "Cleaning work root immediately: $workRoot" -LogPath $mainLogPath
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

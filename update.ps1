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
        throw 'Update manifest is missing the required URL value.'
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
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [switch] $AllInstances
    )

    $allProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) })
    if ($AllInstances) {
        return $allProcesses
    }

    $targetFull = [System.IO.Path]::GetFullPath($TargetInstallDir).TrimEnd('\', '/')
    $targetPrefix = $targetFull + [System.IO.Path]::DirectorySeparatorChar

    return @($allProcesses | Where-Object {
        $exePath = [System.IO.Path]::GetFullPath($_.ExecutablePath)
        return $exePath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-AgentProcesses {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [int] $MaxWaitSeconds = 30,
        [switch] $AllInstances
    )

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $MaxWaitSeconds))
    do {
        $agentProcesses = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir -AllInstances:$AllInstances)
        if (@($agentProcesses).Count -eq 0) {
            return
        }
        foreach ($process in $agentProcesses) {
            Write-Host "Stopping sync_windows_agent.exe [$($process.ProcessId)]"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir -AllInstances:$AllInstances)
    if (@($remaining).Count -gt 0) {
        if ($AllInstances) {
            throw 'Timed out waiting for all sync_windows_agent.exe processes to exit.'
        }
        throw "Timed out waiting for sync_windows_agent.exe to exit from $TargetInstallDir"
    }
}

function Get-WatchdogScriptPath {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    return Join-Path -Path $TargetInstallDir -ChildPath 'sync_windows_agent_watchdog.ps1'
}

function Get-WatchdogScriptContent {
@"
param(
    [switch] `$RunOnce
)

`$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

`$scriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$targetInstallDir = [System.IO.Path]::GetFullPath(`$scriptDir)
`$executablePath = Join-Path -Path `$targetInstallDir -ChildPath 'sync_windows_agent.exe'
`$logPath = Join-Path -Path `$targetInstallDir -ChildPath 'sync_windows_agent_watchdog.log'

function Write-WatchdogLog {
    param([string] `$Message)

    try {
        `$timestamp = [DateTime]::UtcNow.ToString('o')
        Add-Content -LiteralPath `$logPath -Value "[`$timestamp] `$Message" -Encoding ASCII
    } catch {
    }
}

function Get-WatchdogMutexName {
    param([string] `$InstallDir)

    `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$InstallDir.ToLowerInvariant())
    `$hash = [System.Security.Cryptography.SHA256]::HashData(`$bytes)
    return 'Local\SqlSyncAgentWatchdog_' + [System.Convert]::ToHexString(`$hash).Substring(0, 16)
}

function Get-AgentProcesses {
    param([string] `$InstallDir)

    `$targetFull = [System.IO.Path]::GetFullPath(`$InstallDir).TrimEnd('\', '/')
    `$targetPrefix = `$targetFull + [System.IO.Path]::DirectorySeparatorChar

    return @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace(`$_.ExecutablePath) -and
            ([System.IO.Path]::GetFullPath(`$_.ExecutablePath)).StartsWith(`$targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
}

function Start-AgentProcess {
    param(
        [string] `$ExecutablePath,
        [string] `$InstallDir
    )

    if (-not (Test-Path -LiteralPath `$ExecutablePath -PathType Leaf)) {
        Write-WatchdogLog "Executable not found: `$ExecutablePath"
        return
    }

    Write-WatchdogLog 'Starting sync_windows_agent.exe from watchdog.'
    Start-Process -FilePath `$ExecutablePath -ArgumentList '--start-minimized' -WorkingDirectory `$InstallDir -WindowStyle Minimized -ErrorAction SilentlyContinue | Out-Null
}

function Ensure-AgentRunning {
    param(
        [string] `$ExecutablePath,
        [string] `$InstallDir
    )

    `$processes = @(Get-AgentProcesses -InstallDir `$InstallDir)
    if (`$processes.Count -gt 0) {
        return
    }

    Start-AgentProcess -ExecutablePath `$ExecutablePath -InstallDir `$InstallDir
}

`$mutexName = Get-WatchdogMutexName -InstallDir `$targetInstallDir
`$createdNew = `$false
`$mutex = [System.Threading.Mutex]::new(`$true, `$mutexName, [ref] `$createdNew)
if (-not `$createdNew) {
    exit 0
}

try {
    Ensure-AgentRunning -ExecutablePath `$executablePath -InstallDir `$targetInstallDir
    if (`$RunOnce) {
        exit 0
    }

    Write-WatchdogLog 'Watchdog loop started.'
    while (`$true) {
        Start-Sleep -Seconds 30
        Ensure-AgentRunning -ExecutablePath `$executablePath -InstallDir `$targetInstallDir
    }
} finally {
    try {
        `$mutex.ReleaseMutex() | Out-Null
    } catch {
    }
    `$mutex.Dispose()
}
"@
}

function Write-WatchdogScript {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $watchdogPath = Get-WatchdogScriptPath -TargetInstallDir $TargetInstallDir
    Set-Content -LiteralPath $watchdogPath -Value (Get-WatchdogScriptContent) -Encoding ASCII
    return $watchdogPath
}

function Stop-WatchdogProcesses {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $watchdogPath = [System.IO.Path]::GetFullPath((Get-WatchdogScriptPath -TargetInstallDir $TargetInstallDir))
    $powershellProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
            -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
            $_.CommandLine.IndexOf($watchdogPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })

    foreach ($process in $powershellProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-WatchdogProcess {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [switch] $RunOnce
    )

    $watchdogPath = Write-WatchdogScript -TargetInstallDir $TargetInstallDir
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', $watchdogPath
    )
    if ($RunOnce) {
        $arguments += '-RunOnce'
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $TargetInstallDir -WindowStyle Hidden -ErrorAction Stop | Out-Null
}

function Update-StartupShortcutToWatchdog {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        return
    }

    $shortcutPath = Join-Path $appData "Microsoft\Windows\Start Menu\Programs\Startup\SQL Sync Agent.lnk"
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return
    }

    $watchdogPath = Write-WatchdogScript -TargetInstallDir $TargetInstallDir
    $powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = @"
`$ErrorActionPreference = 'Stop'
`$shortcutPath = '$($shortcutPath.Replace("'", "''"))'
`$targetPath = '$($powerShellPath.Replace("'", "''"))'
`$workingDirectory = '$($TargetInstallDir.Replace("'", "''"))'
`$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ''$($watchdogPath.Replace("'", "''"))'''
`$shell = New-Object -ComObject WScript.Shell
`$shortcut = `$shell.CreateShortcut(`$shortcutPath)
`$shortcut.TargetPath = `$targetPath
`$shortcut.Arguments = `$arguments
`$shortcut.WorkingDirectory = `$workingDirectory
`$shortcut.Description = 'SQL Sync Agent'
`$shortcut.Save()
"@
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $script | Out-Null
}

function Start-UpdatedClient {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [Parameter(Mandatory = $true)][string] $InstallDir,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    Write-UpdateLog -Message "Starting updated client executable: $ExecutablePath" -LogPath $LogPath
    try {
        Stop-WatchdogProcesses -TargetInstallDir $InstallDir
        Start-WatchdogProcess -TargetInstallDir $InstallDir
        Write-UpdateLog -Message 'Started watchdog process for updated client.' -LogPath $LogPath
    }
    catch {
        Write-UpdateLog -Message "Failed to start updated client executable: $($_.Exception.Message)" -LogPath $LogPath
        throw
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

function ConvertTo-InstallRelativePath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $normalized = $Path.Replace('\', '/').Trim()
    $normalized = $normalized.TrimStart('/')
    while ($normalized.Contains('//')) {
        $normalized = $normalized.Replace('//', '/')
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Manifest contains an empty relative path.'
    }

    foreach ($segment in $normalized.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Manifest contains an invalid relative path: $Path"
        }
    }

    return $normalized
}

function Resolve-InstallPath {
    param(
        [Parameter(Mandatory = $true)][string] $RootDir,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $safeRelativePath = ConvertTo-InstallRelativePath -Path $RelativePath
    $combinedPath = Join-Path -Path $RootDir -ChildPath ($safeRelativePath -replace '/', '\')
    $rootFullPath = [System.IO.Path]::GetFullPath($RootDir).TrimEnd('\', '/')
    $targetFullPath = [System.IO.Path]::GetFullPath($combinedPath)
    $rootPrefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved path escaped install root: $RelativePath"
    }

    return $targetFullPath
}

function Get-PortableManifestManagedPaths {
    param([Parameter(Mandatory = $true)][string] $ManifestPath)

    $managedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $managedPaths
    }

    foreach ($line in Get-Content -LiteralPath $ManifestPath -ErrorAction Stop) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -match '^[A-Fa-f0-9]{64}\s+(.+)$') {
            [void] $managedPaths.Add((ConvertTo-InstallRelativePath -Path $matches[1]))
        }
    }

    return $managedPaths
}

function Test-InstalledFileMatchesManifest {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][int64] $ExpectedSizeBytes,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($ExpectedSizeBytes -ge 0 -and $fileInfo.Length -ne $ExpectedSizeBytes) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        return $true
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actualHash.Equals($ExpectedSha256.ToLowerInvariant(), [System.StringComparison]::OrdinalIgnoreCase)
}

function Save-UpdateDeleteList {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)] $RelativePaths
    )

    $lines = @($RelativePaths | Sort-Object -Unique)
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

function Start-DeferredInstall {
    param(
        [Parameter(Mandatory = $true)][string] $PayloadDir,
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [Parameter(Mandatory = $true)][string] $WorkRoot,
        [Parameter(Mandatory = $true)][int] $ParentProcessId,
        [string] $DeleteListPath = '',
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
    [string] $DeleteListPath = '',
    [string] $Version = '',
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-AgentProcesses {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [switch] $AllInstances
    )

    $allProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) })
    if ($AllInstances) {
        return $allProcesses
    }

    $targetFull = [System.IO.Path]::GetFullPath($TargetInstallDir).TrimEnd('\', '/')
    $targetPrefix = $targetFull + [System.IO.Path]::DirectorySeparatorChar

    return @($allProcesses | Where-Object {
        $exePath = [System.IO.Path]::GetFullPath($_.ExecutablePath)
        return $exePath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-AgentProcesses {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [int] $MaxWaitSeconds = 30,
        [switch] $AllInstances
    )

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $MaxWaitSeconds))
    do {
        $agentProcesses = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir -AllInstances:$AllInstances)
        if (@($agentProcesses).Count -eq 0) {
            return
        }
        foreach ($process in $agentProcesses) {
            Write-Host "Stopping sync_windows_agent.exe [$($process.ProcessId)]"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(Get-AgentProcesses -TargetInstallDir $TargetInstallDir -AllInstances:$AllInstances)
    if (@($remaining).Count -gt 0) {
        if ($AllInstances) {
            throw 'Timed out waiting for all sync_windows_agent.exe processes to exit.'
        }
        throw "Timed out waiting for sync_windows_agent.exe to exit from $TargetInstallDir"
    }
}

function Start-UpdatedClient {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [Parameter(Mandatory = $true)][string] $InstallDir,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    Write-UpdateLog -Message "Starting updated client executable: $ExecutablePath" -LogPath $LogPath
    try {
        Stop-WatchdogProcesses -TargetInstallDir $InstallDir
        Start-WatchdogProcess -TargetInstallDir $InstallDir
        Write-UpdateLog -Message 'Started watchdog process for updated client.' -LogPath $LogPath
    }
    catch {
        Write-UpdateLog -Message "Failed to start updated client executable: $($_.Exception.Message)" -LogPath $LogPath
        throw
    }
}

function Get-WatchdogScriptPath {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    return Join-Path -Path $TargetInstallDir -ChildPath 'sync_windows_agent_watchdog.ps1'
}

function Get-WatchdogScriptContent {
@"
param(
    [switch] `$RunOnce
)

`$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

`$scriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$targetInstallDir = [System.IO.Path]::GetFullPath(`$scriptDir)
`$executablePath = Join-Path -Path `$targetInstallDir -ChildPath 'sync_windows_agent.exe'
`$logPath = Join-Path -Path `$targetInstallDir -ChildPath 'sync_windows_agent_watchdog.log'

function Write-WatchdogLog {
    param([string] $Message)

    try {
        `$timestamp = [DateTime]::UtcNow.ToString('o')
        Add-Content -LiteralPath `$logPath -Value "[`$timestamp] `$Message" -Encoding ASCII
    } catch {
    }
}

function Get-WatchdogMutexName {
    param([string] $InstallDir)

    `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$InstallDir.ToLowerInvariant())
    `$hash = [System.Security.Cryptography.SHA256]::HashData(`$bytes)
    return 'Local\SqlSyncAgentWatchdog_' + [System.Convert]::ToHexString(`$hash).Substring(0, 16)
}

function Get-AgentProcesses {
    param([string] $InstallDir)

    `$targetFull = [System.IO.Path]::GetFullPath(`$InstallDir).TrimEnd('\', '/')
    `$targetPrefix = `$targetFull + [System.IO.Path]::DirectorySeparatorChar

    return @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
            ([System.IO.Path]::GetFullPath(`$_.ExecutablePath)).StartsWith(`$targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
}

function Start-AgentProcess {
    param(
        [string] $ExecutablePath,
        [string] $InstallDir
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        Write-WatchdogLog "Executable not found: `$ExecutablePath"
        return
    }

    Write-WatchdogLog 'Starting sync_windows_agent.exe from watchdog.'
    Start-Process -FilePath $ExecutablePath -ArgumentList '--start-minimized' -WorkingDirectory $InstallDir -WindowStyle Minimized -ErrorAction SilentlyContinue | Out-Null
}

function Ensure-AgentRunning {
    param(
        [string] $ExecutablePath,
        [string] $InstallDir
    )

    `$processes = @(Get-AgentProcesses -InstallDir `$InstallDir)
    if (`$processes.Count -gt 0) {
        return
    }

    Start-AgentProcess -ExecutablePath $ExecutablePath -InstallDir $InstallDir
}

`$mutexName = Get-WatchdogMutexName -InstallDir `$targetInstallDir
`$createdNew = `$false
`$mutex = [System.Threading.Mutex]::new(`$true, `$mutexName, [ref] `$createdNew)
if (-not `$createdNew) {
    exit 0
}

try {
    Ensure-AgentRunning -ExecutablePath `$executablePath -InstallDir `$targetInstallDir
    if (`$RunOnce) {
        exit 0
    }

    Write-WatchdogLog 'Watchdog loop started.'
    while ($true) {
        Start-Sleep -Seconds 30
        Ensure-AgentRunning -ExecutablePath `$executablePath -InstallDir `$targetInstallDir
    }
} finally {
    try {
        `$mutex.ReleaseMutex() | Out-Null
    } catch {
    }
    `$mutex.Dispose()
}
"@
}

function Write-WatchdogScript {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $watchdogPath = Get-WatchdogScriptPath -TargetInstallDir $TargetInstallDir
    Set-Content -LiteralPath $watchdogPath -Value (Get-WatchdogScriptContent) -Encoding ASCII
    return $watchdogPath
}

function Stop-WatchdogProcesses {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $watchdogPath = [System.IO.Path]::GetFullPath((Get-WatchdogScriptPath -TargetInstallDir $TargetInstallDir))
    $powershellProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
            -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
            $_.CommandLine.IndexOf($watchdogPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })

    foreach ($process in $powershellProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-WatchdogProcess {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $watchdogPath = Write-WatchdogScript -TargetInstallDir $TargetInstallDir
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $watchdogPath) -WorkingDirectory $TargetInstallDir -WindowStyle Hidden -ErrorAction Stop | Out-Null
}

function Update-StartupShortcutToWatchdog {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        return
    }

    $shortcutPath = Join-Path $appData "Microsoft\Windows\Start Menu\Programs\Startup\SQL Sync Agent.lnk"
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return
    }

    $watchdogPath = Write-WatchdogScript -TargetInstallDir $TargetInstallDir
    $powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = @"
`$ErrorActionPreference = 'Stop'
`$shortcutPath = '$($shortcutPath.Replace("'", "''"))'
`$targetPath = '$($powerShellPath.Replace("'", "''"))'
`$workingDirectory = '$($TargetInstallDir.Replace("'", "''"))'
`$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ''$($watchdogPath.Replace("'", "''"))'''
`$shell = New-Object -ComObject WScript.Shell
`$shortcut = `$shell.CreateShortcut(`$shortcutPath)
`$shortcut.TargetPath = `$targetPath
`$shortcut.Arguments = `$arguments
`$shortcut.WorkingDirectory = `$workingDirectory
`$shortcut.Description = 'SQL Sync Agent'
`$shortcut.Save()
"@
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $script | Out-Null
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

function ConvertTo-InstallRelativePath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $normalized = $Path.Replace('\', '/').Trim()
    $normalized = $normalized.TrimStart('/')
    while ($normalized.Contains('//')) {
        $normalized = $normalized.Replace('//', '/')
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Manifest contains an empty relative path.'
    }

    foreach ($segment in $normalized.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Manifest contains an invalid relative path: $Path"
        }
    }

    return $normalized
}

function Resolve-InstallPath {
    param(
        [Parameter(Mandatory = $true)][string] $RootDir,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $safeRelativePath = ConvertTo-InstallRelativePath -Path $RelativePath
    $combinedPath = Join-Path -Path $RootDir -ChildPath ($safeRelativePath -replace '/', '\')
    $rootFullPath = [System.IO.Path]::GetFullPath($RootDir).TrimEnd('\', '/')
    $targetFullPath = [System.IO.Path]::GetFullPath($combinedPath)
    $rootPrefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved path escaped install root: $RelativePath"
    }

    return $targetFullPath
}

function Remove-EmptyParentDirectories {
    param(
        [Parameter(Mandatory = $true)][string] $StartPath,
        [Parameter(Mandatory = $true)][string] $RootDir
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($RootDir).TrimEnd('\', '/')
    $currentPath = Split-Path -Path $StartPath -Parent
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $currentFullPath = [System.IO.Path]::GetFullPath($currentPath).TrimEnd('\', '/')
        if ($currentFullPath.Equals($rootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        if (-not (Test-Path -LiteralPath $currentFullPath -PathType Container)) {
            $currentPath = Split-Path -Path $currentFullPath -Parent
            continue
        }

        $children = @(Get-ChildItem -LiteralPath $currentFullPath -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            break
        }

        Remove-Item -LiteralPath $currentFullPath -Force -ErrorAction SilentlyContinue
        $currentPath = Split-Path -Path $currentFullPath -Parent
    }
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

Write-UpdateLog -Message "Ensuring the prior client instance from this install is stopped before install." -LogPath $logPath
Stop-AgentProcesses -TargetInstallDir $InstallDir

if (-not [string]::IsNullOrWhiteSpace($DeleteListPath) -and (Test-Path -LiteralPath $DeleteListPath -PathType Leaf)) {
    foreach ($relativePath in Get-Content -LiteralPath $DeleteListPath -ErrorAction Stop) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }
        $targetPath = Resolve-InstallPath -RootDir $InstallDir -RelativePath $relativePath
        if (Test-Path -LiteralPath $targetPath) {
            Write-UpdateLog -Message "Removing stale managed file: $relativePath" -LogPath $logPath
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
            Remove-EmptyParentDirectories -StartPath $targetPath -RootDir $InstallDir
        }
    }
}

New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
Write-UpdateLog -Message "Copying payload into install dir." -LogPath $logPath
Get-ChildItem -LiteralPath $PayloadDir -Force |
    Copy-Item -Destination $InstallDir -Recurse -Force
Write-WatchdogScript -TargetInstallDir $InstallDir | Out-Null
Update-StartupShortcutToWatchdog -TargetInstallDir $InstallDir

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
    Write-UpdateLog -Message "Stopping any remaining client instance from this install before relaunch." -LogPath $logPath
    Stop-AgentProcesses -TargetInstallDir $InstallDir
    Start-UpdatedClient -ExecutablePath $installedExe -InstallDir $InstallDir -LogPath $logPath
} else {
    Write-UpdateLog -Message 'NoStart set. Skipping client relaunch.' -LogPath $logPath
}

Write-UpdateLog -Message "Finalize helper cleaning work root: $WorkRoot" -LogPath $logPath
Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
'@

    $watchdogFunctionStart = $helper.IndexOf('function Get-WatchdogScriptContent {')
    $watchdogTemplateStart = $helper.IndexOf('@"', $watchdogFunctionStart)
    $watchdogTemplateEnd = $helper.IndexOf('"@', $watchdogTemplateStart + 2)
    if ($watchdogFunctionStart -lt 0 -or $watchdogTemplateStart -lt 0 -or $watchdogTemplateEnd -lt 0) {
        throw 'Could not isolate the generated watchdog template.'
    }

    $watchdogBody = $helper.Substring(
        $watchdogTemplateStart + 2,
        $watchdogTemplateEnd - ($watchdogTemplateStart + 2)
    ).Replace('`$', '$')
    $helper = $helper.Substring(0, $watchdogTemplateStart) +
        "@'" +
        $watchdogBody +
        "'@" +
        $helper.Substring($watchdogTemplateEnd + 2)

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
    if (-not [string]::IsNullOrWhiteSpace($DeleteListPath)) {
        $startArgs += @('-DeleteListPath', $DeleteListPath)
    }
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
$filesManifestUrlValue = [string] $manifest.filesManifestUrl
$filesManifestUrl = ''
if (-not [string]::IsNullOrWhiteSpace($filesManifestUrlValue)) {
    $filesManifestUrl = Resolve-UpdateUrl -BaseUrl $ManifestUrl -Value $filesManifestUrlValue
}
$zipUrl = Resolve-UpdateUrl -BaseUrl $ManifestUrl -Value ([string] $manifest.zipUrl)

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
$payloadDir = Join-Path -Path $workRoot -ChildPath 'payload'
$deleteListPath = Join-Path -Path $workRoot -ChildPath 'delete.txt'

New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
try {
    if (-not [string]::IsNullOrWhiteSpace($filesManifestUrl)) {
        Write-UpdateLog -Message "Downloading file manifest: $filesManifestUrl" -LogPath $mainLogPath
        $filesManifest = Invoke-UpdateRestMethod -Uri $filesManifestUrl
        $fileEntries = @($filesManifest.files)
        if ($fileEntries.Count -gt 0) {
            $localManagedPaths = Get-PortableManifestManagedPaths -ManifestPath (Join-Path -Path $InstallDir -ChildPath 'portable-manifest.txt')
            $remoteManagedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $staleManagedPaths = [System.Collections.Generic.List[string]]::new()
            $downloadCount = 0
            $downloadBytes = [int64]0

            New-Item -Path $payloadDir -ItemType Directory -Force | Out-Null

            foreach ($fileEntry in $fileEntries) {
                $relativePath = ConvertTo-InstallRelativePath -Path ([string] $fileEntry.path)
                [void] $remoteManagedPaths.Add($relativePath)

                $expectedHash = [string] $fileEntry.sha256
                $expectedSizeBytes = -1
                try {
                    $expectedSizeBytes = [int64] $fileEntry.sizeBytes
                }
                catch {
                    $expectedSizeBytes = -1
                }

                $targetPath = Resolve-InstallPath -RootDir $InstallDir -RelativePath $relativePath
                if (Test-InstalledFileMatchesManifest -Path $targetPath -ExpectedSizeBytes $expectedSizeBytes -ExpectedSha256 $expectedHash) {
                    continue
                }

                $fileUrl = Resolve-UpdateUrl -BaseUrl $filesManifestUrl -Value ([string] $fileEntry.url)
                $stagedPath = Resolve-InstallPath -RootDir $payloadDir -RelativePath $relativePath
                $stagedParent = Split-Path -Path $stagedPath -Parent
                if (-not [string]::IsNullOrWhiteSpace($stagedParent)) {
                    New-Item -Path $stagedParent -ItemType Directory -Force | Out-Null
                }

                Write-UpdateLog -Message "Downloading changed file: $relativePath" -LogPath $mainLogPath
                Invoke-UpdateWebRequest -Uri $fileUrl -OutFile $stagedPath
                if (-not (Test-InstalledFileMatchesManifest -Path $stagedPath -ExpectedSizeBytes $expectedSizeBytes -ExpectedSha256 $expectedHash)) {
                    throw "Downloaded file verification failed: $relativePath"
                }

                $downloadCount += 1
                if ($expectedSizeBytes -gt 0) {
                    $downloadBytes += $expectedSizeBytes
                }
            }

            foreach ($managedPath in $localManagedPaths) {
                if (-not $remoteManagedPaths.Contains($managedPath)) {
                    [void] $staleManagedPaths.Add($managedPath)
                }
            }

            Save-UpdateDeleteList -Path $deleteListPath -RelativePaths $staleManagedPaths
            if ($downloadCount -eq 0 -and $staleManagedPaths.Count -eq 0) {
                Write-UpdateLog -Message "Client files already match target version $($manifest.version)." -LogPath $mainLogPath
                return
            }

            Stop-AgentProcesses -TargetInstallDir $InstallDir
            Write-UpdateLog -Message "Scheduling differential install. files=$downloadCount bytes=$downloadBytes deletes=$($staleManagedPaths.Count)" -LogPath $mainLogPath
            Start-DeferredInstall `
                -PayloadDir $payloadDir `
                -TargetInstallDir $InstallDir `
                -WorkRoot $workRoot `
                -ParentProcessId $PID `
                -DeleteListPath $deleteListPath `
                -Version ([string] $manifest.version) `
                -NoStart:$NoStart
            Write-UpdateLog -Message "Differential updater scheduled for version $($manifest.version) in $InstallDir" -LogPath $mainLogPath
            return
        }
    }

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
        -DeleteListPath $deleteListPath `
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

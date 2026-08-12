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

function Write-UpdateProgress {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][int64] $DownloadedBytes,
        [Parameter(Mandatory = $true)][int64] $TotalBytes,
        [string] $Message = ''
    )

    if ([string]::IsNullOrWhiteSpace($script:UpdateProgressPath)) {
        return
    }
    try {
        $safeDownloaded = [Math]::Max([int64]0, $DownloadedBytes)
        $safeTotal = [Math]::Max([int64]0, $TotalBytes)
        $percent = if ($safeTotal -gt 0) {
            [Math]::Min(100, [Math]::Max(0, [int][Math]::Floor(($safeDownloaded * 100.0) / $safeTotal)))
        } else { 0 }
        $payload = [ordered]@{
            version = $script:UpdateTargetVersion
            status = $Status
            downloadedBytes = $safeDownloaded
            totalBytes = $safeTotal
            percent = $percent
            message = $Message
            updatedAt = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress
        $temporaryPath = "$($script:UpdateProgressPath).$PID.tmp"
        [System.IO.File]::WriteAllText($temporaryPath, $payload, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:UpdateProgressPath -Force
    }
    catch {
        # Progress reporting is best effort and must never break the update.
    }
}

function Publish-UpdateDownloadProgress {
    param(
        [Parameter(Mandatory = $true)][int64] $FileBytes,
        [Parameter(Mandatory = $true)][int64] $AggregateCompletedBytes,
        [Parameter(Mandatory = $true)][int64] $TotalDownloadBytes
    )

    $downloaded = [Math]::Min($TotalDownloadBytes, [Math]::Max([int64]0, $AggregateCompletedBytes + $FileBytes))
    $now = [DateTime]::UtcNow
    $percent = if ($TotalDownloadBytes -gt 0) { [int][Math]::Floor(($downloaded * 100.0) / $TotalDownloadBytes) } else { 0 }
    $due = $script:LastUpdateProgressAt -eq [DateTime]::MinValue -or
        $percent -ne $script:LastUpdateProgressPercent -or
        ($downloaded - $script:LastUpdateProgressBytes) -ge 1MB -or
        ($now - $script:LastUpdateProgressAt).TotalSeconds -ge 2
    if (-not $due) {
        return
    }
    Write-UpdateProgress -Status 'downloading' -DownloadedBytes $downloaded -TotalBytes $TotalDownloadBytes -Message 'Downloading the verified client update.'
    $script:LastUpdateProgressAt = $now
    $script:LastUpdateProgressBytes = $downloaded
    $script:LastUpdateProgressPercent = $percent
}

if (-not ('SqlSyncAgentUpdateWebClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;

public sealed class SqlSyncAgentUpdateWebClient : WebClient
{
    public int ConnectTimeoutMilliseconds { get; set; }
    public int ReadWriteTimeoutMilliseconds { get; set; }

    public SqlSyncAgentUpdateWebClient()
    {
        ConnectTimeoutMilliseconds = 45000;
        ReadWriteTimeoutMilliseconds = 300000;
    }

    protected override WebRequest GetWebRequest(Uri address)
    {
        WebRequest request = base.GetWebRequest(address);
        request.Timeout = ConnectTimeoutMilliseconds;
        HttpWebRequest httpRequest = request as HttpWebRequest;
        if (httpRequest != null)
        {
            httpRequest.ReadWriteTimeout = ReadWriteTimeoutMilliseconds;
        }
        return request;
    }
}
'@
}

function New-UpdateWebClient {
    Initialize-NetworkSecurityProtocol
    $client = [SqlSyncAgentUpdateWebClient]::new()
    $client.Headers[[System.Net.HttpRequestHeader]::UserAgent] = 'SqlSyncAgentUpdater/1.0'
    return $client
}

function Invoke-UpdateRestMethod {
    param([Parameter(Mandatory = $true)][string] $Uri)

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $client = New-UpdateWebClient
        try {
            $content = $client.DownloadString($Uri)
            return $content | ConvertFrom-Json
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
            }
        }
        finally {
            $client.Dispose()
        }
    }
    throw "Update metadata download failed after 3 bounded attempts: $Uri. $($lastError.Exception.Message)"
}

function Invoke-ResumableUpdateWebRequest {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $OutFile,
        [Parameter(Mandatory = $true)][int64] $ExpectedSizeBytes,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256,
        [int64] $AggregateCompletedBytes = 0,
        [int64] $TotalDownloadBytes = 0
    )

    $partialFile = "$OutFile.part"
    $parent = Split-Path -Path $OutFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    if (Test-InstalledFileMatchesManifest -Path $OutFile -ExpectedSizeBytes $ExpectedSizeBytes -ExpectedSha256 $ExpectedSha256) {
        Publish-UpdateDownloadProgress -FileBytes $ExpectedSizeBytes -AggregateCompletedBytes $AggregateCompletedBytes -TotalDownloadBytes $TotalDownloadBytes
        return
    }
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $response = $null
        $responseStream = $null
        $fileStream = $null
        try {
            Initialize-NetworkSecurityProtocol
            if (Test-InstalledFileMatchesManifest -Path $partialFile -ExpectedSizeBytes $ExpectedSizeBytes -ExpectedSha256 $ExpectedSha256) {
                Move-Item -LiteralPath $partialFile -Destination $OutFile -Force
                Publish-UpdateDownloadProgress -FileBytes $ExpectedSizeBytes -AggregateCompletedBytes $AggregateCompletedBytes -TotalDownloadBytes $TotalDownloadBytes
                return
            }
            $existingBytes = [int64]0
            if (Test-Path -LiteralPath $partialFile -PathType Leaf) {
                $existingBytes = [int64](Get-Item -LiteralPath $partialFile).Length
            }
            if ($ExpectedSizeBytes -ge 0 -and $existingBytes -ge $ExpectedSizeBytes) {
                Remove-Item -LiteralPath $partialFile -Force
                $existingBytes = 0
            }
            Publish-UpdateDownloadProgress -FileBytes $existingBytes -AggregateCompletedBytes $AggregateCompletedBytes -TotalDownloadBytes $TotalDownloadBytes

            $request = [System.Net.HttpWebRequest]::Create($Uri)
            $request.Method = 'GET'
            $request.UserAgent = 'SqlSyncAgentUpdater/1.0'
            $request.Timeout = 45000
            $request.ReadWriteTimeout = 300000
            if ($existingBytes -gt 0) {
                $request.AddRange($existingBytes)
            }
            $response = [System.Net.HttpWebResponse]$request.GetResponse()
            $append = $existingBytes -gt 0 -and $response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent
            if (-not $append) {
                $existingBytes = 0
            }
            $fileMode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fileStream = [System.IO.File]::Open($partialFile, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $responseStream = $response.GetResponseStream()
            $buffer = New-Object byte[] 65536
            while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $existingBytes += $read
                Publish-UpdateDownloadProgress -FileBytes $existingBytes -AggregateCompletedBytes $AggregateCompletedBytes -TotalDownloadBytes $TotalDownloadBytes
            }
            $fileStream.Flush()
            $fileStream.Dispose()
            $fileStream = $null
            $responseStream.Dispose()
            $responseStream = $null
            $response.Dispose()
            $response = $null

            if (-not (Test-InstalledFileMatchesManifest -Path $partialFile -ExpectedSizeBytes $ExpectedSizeBytes -ExpectedSha256 $ExpectedSha256)) {
                $actualSize = [int64](Get-Item -LiteralPath $partialFile).Length
                if ($ExpectedSizeBytes -ge 0 -and $actualSize -lt $ExpectedSizeBytes) {
                    throw "Resumable download is incomplete: $actualSize of $ExpectedSizeBytes bytes."
                }
                Remove-Item -LiteralPath $partialFile -Force -ErrorAction SilentlyContinue
                throw 'Downloaded payload failed its size or SHA-256 verification.'
            }
            Move-Item -LiteralPath $partialFile -Destination $OutFile -Force
            Publish-UpdateDownloadProgress -FileBytes $ExpectedSizeBytes -AggregateCompletedBytes $AggregateCompletedBytes -TotalDownloadBytes $TotalDownloadBytes
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
            }
        }
        finally {
            if ($null -ne $fileStream) { $fileStream.Dispose() }
            if ($null -ne $responseStream) { $responseStream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
        }
    }
    throw "Resumable update payload download failed after 3 bounded attempts: $Uri. Partial bytes were preserved for the next updater run. $($lastError.Exception.Message)"
}

function Expand-VerifiedGzipUpdateFile {
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [Parameter(Mandatory = $true)][string] $DestinationPath
    )

    $inputStream = [System.IO.File]::Open($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $gzipStream = [System.IO.Compression.GZipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
    $outputStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $gzipStream.CopyTo($outputStream)
        $outputStream.Flush()
    }
    finally {
        $outputStream.Dispose()
        $gzipStream.Dispose()
        $inputStream.Dispose()
    }
}

function Get-DefaultInstallDir {
    $portableExe = Join-Path -Path $PSScriptRoot -ChildPath 'sync_windows_agent.exe'
    if (Test-Path -LiteralPath $portableExe -PathType Leaf) {
        return $PSScriptRoot
    }

    return Join-Path -Path $env:LOCALAPPDATA -ChildPath 'MicrosoftSqlServerSync\sync_windows_agent'
}

function Get-UpdateMutexName {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(
            ([System.IO.Path]::GetFullPath($TargetInstallDir)).ToLowerInvariant()
        )
        $hash = $sha256.ComputeHash($bytes)
        $prefix = ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16)
        return "Local\SqlSyncAgentUpdater_$prefix"
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertTo-ComparableClientVersion {
    param([Parameter(Mandatory = $true)][string] $Value)

    $match = [System.Text.RegularExpressions.Regex]::Match(
        $Value.Trim(),
        '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?'
    )
    if (-not $match.Success) {
        return $null
    }
    return @(
        [int64] $match.Groups[1].Value,
        [int64] $match.Groups[2].Value,
        [int64] $match.Groups[3].Value,
        $(if ($match.Groups[4].Success) { [int64] $match.Groups[4].Value } else { [int64] 0 })
    )
}

function Compare-ClientVersions {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right
    )

    $leftParts = ConvertTo-ComparableClientVersion -Value $Left
    $rightParts = ConvertTo-ComparableClientVersion -Value $Right
    if ($null -eq $leftParts -or $null -eq $rightParts) {
        return $null
    }
    for ($index = 0; $index -lt 4; $index++) {
        if ($leftParts[$index] -lt $rightParts[$index]) {
            return -1
        }
        if ($leftParts[$index] -gt $rightParts[$index]) {
            return 1
        }
    }
    return 0
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

function Test-PayloadInstalled {
    param(
        [Parameter(Mandatory = $true)][string] $PayloadDir,
        [Parameter(Mandatory = $true)][string] $InstallDir
    )

    foreach ($source in Get-ChildItem -LiteralPath $PayloadDir -File -Recurse -Force) {
        $relative = $source.FullName.Substring(($PayloadDir.TrimEnd('\', '/')).Length).TrimStart('\', '/')
        $target = Join-Path -Path $InstallDir -ChildPath $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Installed client file is missing: $relative"
        }
        $sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($sourceHash -ne $targetHash) {
            throw "Installed client file verification failed: $relative"
        }
    }
}

function Get-SupervisorScriptPath {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    return Join-Path -Path $TargetInstallDir -ChildPath 'sync_windows_agent_supervisor.ps1'
}

function Remove-ObsoleteLaunchRegistrations {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    $supervisorPath = [System.IO.Path]::GetFullPath((Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir))
    $retiredShortcuts = 0
    $retiredRunValues = 0
    $retiredTasks = 0
    $startupRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $startupRoots += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $startupRoots += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($startupRoot in $startupRoots) {
            if (-not (Test-Path -LiteralPath $startupRoot -PathType Container)) { continue }
            foreach ($shortcutFile in Get-ChildItem -LiteralPath $startupRoot -Filter '*.lnk' -File -ErrorAction SilentlyContinue) {
                try {
                    $shortcut = $shell.CreateShortcut($shortcutFile.FullName)
                    $launchText = "$($shortcut.TargetPath) $($shortcut.Arguments)"
                    if ($launchText.IndexOf('sync_windows_agent', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                    if ($launchText.IndexOf($supervisorPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
                    Remove-Item -LiteralPath $shortcutFile.FullName -Force -ErrorAction Stop
                    $retiredShortcuts += 1
                }
                catch {
                    Write-UpdateLog -Message "Could not retire obsolete startup shortcut $($shortcutFile.FullName): $($_.Exception.Message)" -LogPath $LogPath
                }
            }
        }
    }
    catch {
        Write-UpdateLog -Message "Could not inspect Windows startup shortcuts: $($_.Exception.Message)" -LogPath $LogPath
    }

    foreach ($runKeyPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )) {
        try {
            if (-not (Test-Path -LiteralPath $runKeyPath)) { continue }
            $runKey = Get-ItemProperty -LiteralPath $runKeyPath -ErrorAction Stop
            foreach ($property in $runKey.PSObject.Properties) {
                if ($property.Name -like 'PS*' -or $property.Value -isnot [string]) { continue }
                $launchText = [string] $property.Value
                if ($launchText.IndexOf('sync_windows_agent', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                if ($launchText.IndexOf($supervisorPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
                Remove-ItemProperty -LiteralPath $runKeyPath -Name $property.Name -Force -ErrorAction Stop
                $retiredRunValues += 1
            }
        }
        catch {
            Write-UpdateLog -Message "Could not inspect Windows Run key ${runKeyPath}: $($_.Exception.Message)" -LogPath $LogPath
        }
    }

    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        foreach ($task in Get-ScheduledTask -ErrorAction SilentlyContinue) {
            try {
                $launchText = (($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ')
                if ($launchText.IndexOf('sync_windows_agent', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                if ($launchText.IndexOf($supervisorPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
                $retiredTasks += 1
            }
            catch {
                Write-UpdateLog -Message "Could not disable obsolete scheduled task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)" -LogPath $LogPath
            }
        }
    }

    Write-UpdateLog -Message "Updater retired obsolete launch registrations before replacement. shortcuts=$retiredShortcuts runValues=$retiredRunValues scheduledTasks=$retiredTasks" -LogPath $LogPath
}

function Stop-SupervisorProcesses {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $supervisorPath = [System.IO.Path]::GetFullPath((Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir))
    $legacyWatchdogPath = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $TargetInstallDir -ChildPath 'sync_windows_agent_watchdog.ps1')
    )
    $powershellProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
            -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
            (
                $_.CommandLine.IndexOf($supervisorPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.CommandLine.IndexOf($legacyWatchdogPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            )
        })

    foreach ($process in $powershellProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-SupervisorProcess {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir
    )

    $supervisorPath = Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir
    if (-not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        throw "Independent supervisor is missing: $supervisorPath"
    }
    $quotedSupervisorPath = "'" + $supervisorPath.Replace("'", "''") + "'"
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes("& $quotedSupervisorPath")
    )
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-EncodedCommand', $encodedCommand
    )
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $supervisorProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $TargetInstallDir -WindowStyle Hidden -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        $supervisorProcess.Refresh()
        if (-not $supervisorProcess.HasExited) { return }
        if ($attempt -lt 10) { Start-Sleep -Milliseconds 500 }
    }
    throw 'Independent supervisor exited during every bounded startup attempt.'
}

function Update-StartupShortcutToSupervisor {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        return
    }

    $shortcutPath = Join-Path $appData "Microsoft\Windows\Start Menu\Programs\Startup\SQL Sync Agent.lnk"
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return
    }

    $supervisorPath = Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir
    if (-not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        throw "Independent supervisor is missing: $supervisorPath"
    }
    $powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = @"
`$ErrorActionPreference = 'Stop'
`$shortcutPath = '$($shortcutPath.Replace("'", "''"))'
`$targetPath = '$($powerShellPath.Replace("'", "''"))'
`$workingDirectory = '$($TargetInstallDir.Replace("'", "''"))'
`$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ''$($supervisorPath.Replace("'", "''"))'''
`$shell = New-Object -ComObject WScript.Shell
`$shortcut = `$shell.CreateShortcut(`$shortcutPath)
`$shortcut.TargetPath = `$targetPath
`$shortcut.Arguments = `$arguments
`$shortcut.WorkingDirectory = `$workingDirectory
`$shortcut.Description = 'SQL Sync Agent Supervisor'
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

    $userStoppedMarkerPath = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.user-stopped'
    if (Test-Path -LiteralPath $userStoppedMarkerPath -PathType Leaf) {
        Write-UpdateLog -Message 'Updated client remains stopped because the user closed it. A manual launch is required.' -LogPath $LogPath
        return
    }

    Write-UpdateLog -Message "Starting updated client executable: $ExecutablePath" -LogPath $LogPath
    try {
        Stop-SupervisorProcesses -TargetInstallDir $InstallDir
        Start-SupervisorProcess -TargetInstallDir $InstallDir
        Write-UpdateLog -Message 'Started independent supervisor for updated client.' -LogPath $LogPath
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

function Test-PayloadInstalled {
    param(
        [Parameter(Mandatory = $true)][string] $PayloadDir,
        [Parameter(Mandatory = $true)][string] $InstallDir
    )

    foreach ($source in Get-ChildItem -LiteralPath $PayloadDir -File -Recurse -Force) {
        $relative = $source.FullName.Substring(($PayloadDir.TrimEnd('\', '/')).Length).TrimStart('\', '/')
        $target = Join-Path -Path $InstallDir -ChildPath $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Installed client file is missing: $relative"
        }
        $sourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($sourceHash -ne $targetHash) {
            throw "Installed client file verification failed: $relative"
        }
    }
}

function Start-UpdatedClient {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [Parameter(Mandatory = $true)][string] $InstallDir,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    $userStoppedMarkerPath = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.user-stopped'
    if (Test-Path -LiteralPath $userStoppedMarkerPath -PathType Leaf) {
        Write-UpdateLog -Message 'Updated client remains stopped because the user closed it. A manual launch is required.' -LogPath $LogPath
        return
    }

    Write-UpdateLog -Message "Starting updated client through independent supervisor: $ExecutablePath" -LogPath $LogPath
    try {
        Stop-SupervisorProcesses -TargetInstallDir $InstallDir
        Start-SupervisorProcess -TargetInstallDir $InstallDir
        Write-UpdateLog -Message 'Started independent supervisor for updated client.' -LogPath $LogPath
    }
    catch {
        Write-UpdateLog -Message "Failed to start updated client executable: $($_.Exception.Message)" -LogPath $LogPath
        throw
    }
}

function Get-SupervisorScriptPath {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    return Join-Path -Path $TargetInstallDir -ChildPath 'sync_windows_agent_supervisor.ps1'
}

function Stop-SupervisorProcesses {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $supervisorPath = [System.IO.Path]::GetFullPath((Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir))
    $legacyWatchdogPath = [System.IO.Path]::GetFullPath((Join-Path -Path $TargetInstallDir -ChildPath 'sync_windows_agent_watchdog.ps1'))
    $powershellProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
            -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
            (
                $_.CommandLine.IndexOf($supervisorPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.CommandLine.IndexOf($legacyWatchdogPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            )
        })

    foreach ($process in $powershellProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-SupervisorProcess {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $supervisorPath = Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir
    if (-not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        throw "Independent supervisor is missing: $supervisorPath"
    }
    $quotedSupervisorPath = "'" + $supervisorPath.Replace("'", "''") + "'"
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes("& $quotedSupervisorPath")
    )
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encodedCommand)
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $supervisorProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $TargetInstallDir -WindowStyle Hidden -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        $supervisorProcess.Refresh()
        if (-not $supervisorProcess.HasExited) { return }
        if ($attempt -lt 10) { Start-Sleep -Milliseconds 500 }
    }
    throw 'Independent supervisor exited during every bounded startup attempt.'
}

function Update-StartupShortcutToSupervisor {
    param([Parameter(Mandatory = $true)][string] $TargetInstallDir)

    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        return
    }

    $shortcutPath = Join-Path $appData "Microsoft\Windows\Start Menu\Programs\Startup\SQL Sync Agent.lnk"
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        return
    }

    $supervisorPath = Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir
    if (-not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        throw "Independent supervisor is missing: $supervisorPath"
    }
    $powerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = @"
`$ErrorActionPreference = 'Stop'
`$shortcutPath = '$($shortcutPath.Replace("'", "''"))'
`$targetPath = '$($powerShellPath.Replace("'", "''"))'
`$workingDirectory = '$($TargetInstallDir.Replace("'", "''"))'
`$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ''$($supervisorPath.Replace("'", "''"))'''
`$shell = New-Object -ComObject WScript.Shell
`$shortcut = `$shell.CreateShortcut(`$shortcutPath)
`$shortcut.TargetPath = `$targetPath
`$shortcut.Arguments = `$arguments
`$shortcut.WorkingDirectory = `$workingDirectory
`$shortcut.Description = 'SQL Sync Agent Supervisor'
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

function Stop-ObsoleteInstallProcesses {
    param(
        [Parameter(Mandatory = $true)][string] $TargetInstallDir,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    $targetFull = [System.IO.Path]::GetFullPath($TargetInstallDir).TrimEnd('\', '/')
    $targetPrefix = $targetFull + [System.IO.Path]::DirectorySeparatorChar
    $targetSupervisor = [System.IO.Path]::GetFullPath((Get-SupervisorScriptPath -TargetInstallDir $TargetInstallDir))
    $stoppedSupervisors = 0
    $stoppedAgents = 0

    $powershellProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
            $_.ProcessId -ne $PID -and
            -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
            (
                $_.CommandLine.IndexOf('sync_windows_agent_supervisor.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.CommandLine.IndexOf('sync_windows_agent_watchdog.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            ) -and
            $_.CommandLine.IndexOf($targetSupervisor, [System.StringComparison]::OrdinalIgnoreCase) -lt 0
        })
    foreach ($process in $powershellProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        $stoppedSupervisors += 1
    }

    $agentProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
            -not ([System.IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith(
                $targetPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        })
    foreach ($process in $agentProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        $stoppedAgents += 1
    }

    Write-UpdateLog -Message "Updater retired obsolete running installs before replacement. supervisors=$stoppedSupervisors agents=$stoppedAgents" -LogPath $LogPath
}

function Save-InstallRollbackSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $PayloadDir,
        [Parameter(Mandatory = $true)][string] $InstallDir,
        [Parameter(Mandatory = $true)][string] $RollbackDir,
        [Parameter(Mandatory = $true)][string] $CreatedListPath,
        [string] $DeleteListPath = ''
    )

    New-Item -Path $RollbackDir -ItemType Directory -Force | Out-Null
    $createdPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $managedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($source in Get-ChildItem -LiteralPath $PayloadDir -File -Recurse -Force) {
        $relative = $source.FullName.Substring(($PayloadDir.TrimEnd('\', '/')).Length).TrimStart('\', '/')
        [void] $managedPaths.Add($relative)
    }
    if (-not [string]::IsNullOrWhiteSpace($DeleteListPath) -and (Test-Path -LiteralPath $DeleteListPath -PathType Leaf)) {
        foreach ($relative in Get-Content -LiteralPath $DeleteListPath -ErrorAction Stop) {
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                [void] $managedPaths.Add($relative)
            }
        }
    }

    foreach ($relative in $managedPaths) {
        $target = Resolve-InstallPath -RootDir $InstallDir -RelativePath $relative
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $backup = Resolve-InstallPath -RootDir $RollbackDir -RelativePath $relative
            $backupParent = Split-Path -Path $backup -Parent
            New-Item -Path $backupParent -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $backup -Force
        }
        else {
            [void] $createdPaths.Add($relative)
        }
    }
    Set-Content -LiteralPath $CreatedListPath -Value @($createdPaths) -Encoding UTF8
}

function Restore-InstallRollbackSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $InstallDir,
        [Parameter(Mandatory = $true)][string] $RollbackDir,
        [Parameter(Mandatory = $true)][string] $CreatedListPath,
        [Parameter(Mandatory = $true)][string] $LogPath
    )

    Write-UpdateLog -Message 'Post-update startup verification failed; rolling back the complete managed-file change set.' -LogPath $LogPath
    Stop-SupervisorProcesses -TargetInstallDir $InstallDir
    Stop-AgentProcesses -TargetInstallDir $InstallDir
    if (Test-Path -LiteralPath $CreatedListPath -PathType Leaf) {
        foreach ($relative in Get-Content -LiteralPath $CreatedListPath -ErrorAction Stop) {
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $target = Resolve-InstallPath -RootDir $InstallDir -RelativePath $relative
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $RollbackDir -PathType Container) {
        foreach ($backup in Get-ChildItem -LiteralPath $RollbackDir -File -Recurse -Force) {
            $relative = $backup.FullName.Substring(($RollbackDir.TrimEnd('\', '/')).Length).TrimStart('\', '/')
            $target = Resolve-InstallPath -RootDir $InstallDir -RelativePath $relative
            $targetParent = Split-Path -Path $target -Parent
            New-Item -Path $targetParent -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $backup.FullName -Destination $target -Force
        }
    }
    Write-UpdateLog -Message 'Rollback files restored and verified; restarting the previous client.' -LogPath $LogPath
    Start-UpdatedClient -ExecutablePath (Join-Path $InstallDir 'sync_windows_agent.exe') -InstallDir $InstallDir -LogPath $LogPath
}

function Wait-AgentStartupStable {
    param(
        [Parameter(Mandatory = $true)][string] $InstallDir,
        [ValidateRange(1, 120)][int] $RequiredStableSeconds = 10,
        [ValidateRange(1, 300)][int] $TimeoutSeconds = 45
    )

    $stableSeconds = 0
    for ($elapsed = 0; $elapsed -lt $TimeoutSeconds; $elapsed++) {
        Start-Sleep -Seconds 1
        if (@(Get-AgentProcesses -TargetInstallDir $InstallDir).Count -gt 0) {
            $stableSeconds += 1
            if ($stableSeconds -ge $RequiredStableSeconds) { return $true }
        }
        else {
            $stableSeconds = 0
        }
    }
    return $false
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

Write-UpdateLog -Message "Stopping the supervisor before replacing client files." -LogPath $logPath
Stop-SupervisorProcesses -TargetInstallDir $InstallDir
Write-UpdateLog -Message "Ensuring the prior client instance from this install is stopped before install." -LogPath $logPath
Stop-AgentProcesses -TargetInstallDir $InstallDir
Start-Sleep -Milliseconds 500

$rollbackDir = Join-Path -Path $WorkRoot -ChildPath 'rollback'
$createdListPath = Join-Path -Path $WorkRoot -ChildPath 'rollback-created.txt'
Write-UpdateLog -Message 'Saving transactional rollback snapshot for every managed file that will change.' -LogPath $logPath
Save-InstallRollbackSnapshot -PayloadDir $PayloadDir -InstallDir $InstallDir -RollbackDir $rollbackDir -CreatedListPath $createdListPath -DeleteListPath $DeleteListPath

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
Test-PayloadInstalled -PayloadDir $PayloadDir -InstallDir $InstallDir
Update-StartupShortcutToSupervisor -TargetInstallDir $InstallDir

$installedExe = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.exe'
if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    throw "Update completed but the installed executable is missing: $installedExe"
}
Write-UpdateLog -Message "Verified installed client payload for version $Version." -LogPath $logPath

if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-UpdateLog -Message "Installed sync_windows_agent to $InstallDir" -LogPath $logPath
} else {
    Write-UpdateLog -Message "Installed sync_windows_agent version $Version to $InstallDir" -LogPath $logPath
}

if (-not $NoStart) {
    Write-UpdateLog -Message "Stopping any remaining client instance from this install before relaunch." -LogPath $logPath
    Stop-AgentProcesses -TargetInstallDir $InstallDir
    $userStoppedMarkerPath = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.user-stopped'
    if (-not (Test-Path -LiteralPath $userStoppedMarkerPath -PathType Leaf)) {
        Write-UpdateLog -Message 'Verifying that the updated client process remains healthy after restart.' -LogPath $logPath
        $startupStableSeconds = 10
        $startupTimeoutSeconds = 45
        if (-not [string]::IsNullOrWhiteSpace($env:SYNC_WINDOWS_AGENT_UPDATE_STABLE_SECONDS)) {
            $startupStableSeconds = [Math]::Max(1, [Math]::Min(120, [int] $env:SYNC_WINDOWS_AGENT_UPDATE_STABLE_SECONDS))
        }
        if (-not [string]::IsNullOrWhiteSpace($env:SYNC_WINDOWS_AGENT_UPDATE_STARTUP_TIMEOUT_SECONDS)) {
            $startupTimeoutSeconds = [Math]::Max($startupStableSeconds, [Math]::Min(300, [int] $env:SYNC_WINDOWS_AGENT_UPDATE_STARTUP_TIMEOUT_SECONDS))
        }
        $updatedClientStable = $false
        try {
            Start-UpdatedClient -ExecutablePath $installedExe -InstallDir $InstallDir -LogPath $logPath
            $updatedClientStable = Wait-AgentStartupStable -InstallDir $InstallDir -RequiredStableSeconds $startupStableSeconds -TimeoutSeconds $startupTimeoutSeconds
        }
        catch {
            Write-UpdateLog -Message "Updated client launch failed before stability verification: $($_.Exception.Message)" -LogPath $logPath
        }
        if (-not $updatedClientStable) {
            Restore-InstallRollbackSnapshot -InstallDir $InstallDir -RollbackDir $rollbackDir -CreatedListPath $createdListPath -LogPath $logPath
            if (-not (Wait-AgentStartupStable -InstallDir $InstallDir -RequiredStableSeconds $startupStableSeconds -TimeoutSeconds $startupTimeoutSeconds)) {
                throw 'The updated client failed startup verification and the restored previous client also failed to remain running.'
            }
            throw 'The updated client failed startup verification. The previous version was restored and restarted safely; the supervisor will retry later.'
        }
        Write-UpdateLog -Message 'Updated client startup verification passed.' -LogPath $logPath
    }
    else {
        Start-UpdatedClient -ExecutablePath $installedExe -InstallDir $InstallDir -LogPath $logPath
    }
} else {
    Write-UpdateLog -Message 'NoStart set. Skipping client relaunch.' -LogPath $logPath
}

Write-UpdateLog -Message "Finalize helper cleaning work root: $WorkRoot" -LogPath $logPath
Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
'@

    Set-Content -LiteralPath $helperPath -Value $helper -Encoding ASCII

    $quotedHelperPath = "'" + $helperPath.Replace("'", "''") + "'"
    $quotedPayloadDir = "'" + $PayloadDir.Replace("'", "''") + "'"
    $quotedInstallDir = "'" + $TargetInstallDir.Replace("'", "''") + "'"
    $quotedWorkRoot = "'" + $WorkRoot.Replace("'", "''") + "'"
    $deferredCommand = "& $quotedHelperPath -PayloadDir $quotedPayloadDir -InstallDir $quotedInstallDir -WorkRoot $quotedWorkRoot -ParentProcessId $ParentProcessId"
    if (-not [string]::IsNullOrWhiteSpace($DeleteListPath)) {
        $quotedDeleteListPath = "'" + $DeleteListPath.Replace("'", "''") + "'"
        $deferredCommand += " -DeleteListPath $quotedDeleteListPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $quotedVersion = "'" + $Version.Replace("'", "''") + "'"
        $deferredCommand += " -Version $quotedVersion"
    }
    if ($NoStart) {
        $deferredCommand += ' -NoStart'
    }
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($deferredCommand)
    )
    $startArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encodedCommand
    )

    Start-Process -FilePath 'powershell.exe' -ArgumentList $startArgs -WorkingDirectory $WorkRoot -WindowStyle Hidden
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Get-DefaultInstallDir
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$mainLogPath = Join-Path -Path $InstallDir -ChildPath 'update.log'
$script:UpdateProgressPath = Join-Path -Path $InstallDir -ChildPath 'update-progress.json'
$script:UpdateTargetVersion = ''
$script:LastUpdateProgressAt = [DateTime]::MinValue
$script:LastUpdateProgressBytes = [int64]-1
$script:LastUpdateProgressPercent = -1
Write-UpdateLog -Message "Updater starting. manifest=$ManifestUrl install=$InstallDir noStart=$NoStart" -LogPath $mainLogPath
$updateMutex = [System.Threading.Mutex]::new($false, (Get-UpdateMutexName -TargetInstallDir $InstallDir))
$updateMutexAcquired = $false
try {
    $updateMutexAcquired = $updateMutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $updateMutexAcquired = $true
}
if (-not $updateMutexAcquired) {
    Write-UpdateLog -Message 'Another updater owns this installation; skipping the duplicate update request before network access.' -LogPath $mainLogPath
    $updateMutex.Dispose()
    return
}

$manifest = Invoke-UpdateRestMethod -Uri $ManifestUrl
$script:UpdateTargetVersion = [string] $manifest.version
$installedExeForVersion = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.exe'
if (Test-Path -LiteralPath $installedExeForVersion -PathType Leaf) {
    $installedVersion = [string] (Get-Item -LiteralPath $installedExeForVersion).VersionInfo.ProductVersion
    $targetVersion = [string] $manifest.version
    $versionComparison = Compare-ClientVersions -Left $targetVersion -Right $installedVersion
    if ($null -ne $versionComparison -and $versionComparison -lt 0) {
        Write-UpdateLog -Message "Skipping downgrade from installed version $installedVersion to target version $targetVersion." -LogPath $mainLogPath
        return
    }
}
$filesManifestUrlValue = [string] $manifest.filesManifestUrl
$filesManifestUrl = ''
if (-not [string]::IsNullOrWhiteSpace($filesManifestUrlValue)) {
    $filesManifestUrl = Resolve-UpdateUrl -BaseUrl $ManifestUrl -Value $filesManifestUrlValue
}
$zipUrl = Resolve-UpdateUrl -BaseUrl $ManifestUrl -Value ([string] $manifest.zipUrl)
$safeTargetVersion = ([string]$manifest.version) -replace '[^A-Za-z0-9._-]', '-'
$persistentCacheRoot = Join-Path -Path $InstallDir -ChildPath ".update-cache\$safeTargetVersion"

$requiredFreeBytes = 512MB
$declaredSizeBytes = [int64]-1
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
        if ([string] $filesManifest.version -ne [string] $manifest.version -or [string] $filesManifest.commit -ne [string] $manifest.commit) {
            throw "Immutable file manifest identity does not match the selected client release."
        }
        $fileEntries = @($filesManifest.files)
        if ($fileEntries.Count -gt 0) {
            $localManagedPaths = Get-PortableManifestManagedPaths -ManifestPath (Join-Path -Path $InstallDir -ChildPath 'portable-manifest.txt')
            $remoteManagedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $staleManagedPaths = [System.Collections.Generic.List[string]]::new()
            $downloadCount = 0
            $downloadBytes = [int64]0
            $totalDownloadBytes = [int64]0
            foreach ($fileEntry in $fileEntries) {
                $relativePath = ConvertTo-InstallRelativePath -Path ([string] $fileEntry.path)
                $expectedSizeBytes = [int64] $fileEntry.sizeBytes
                $expectedHash = [string] $fileEntry.sha256
                $targetPath = Resolve-InstallPath -RootDir $InstallDir -RelativePath $relativePath
                if (Test-InstalledFileMatchesManifest -Path $targetPath -ExpectedSizeBytes $expectedSizeBytes -ExpectedSha256 $expectedHash) {
                    continue
                }
                $transferSizeBytes = $expectedSizeBytes
                if ($null -ne $fileEntry.PSObject.Properties['compression'] -and
                    ([string] $fileEntry.compression).Trim().ToLowerInvariant() -eq 'gzip') {
                    $transferSizeBytes = [int64] $fileEntry.transferSizeBytes
                }
                if ($transferSizeBytes -gt 0) {
                    $totalDownloadBytes += $transferSizeBytes
                }
            }
            $completedDownloadBytes = [int64]0
            Write-UpdateProgress -Status 'downloading' -DownloadedBytes 0 -TotalBytes $totalDownloadBytes -Message 'Preparing the verified differential download.'

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

                $compression = ''
                $transferUrlValue = [string] $fileEntry.url
                $transferHash = $expectedHash
                $transferSizeBytes = $expectedSizeBytes
                if ($null -ne $fileEntry.PSObject.Properties['compression']) {
                    $compression = ([string] $fileEntry.compression).Trim().ToLowerInvariant()
                }
                if ($compression -eq 'gzip') {
                    $transferUrlValue = [string] $fileEntry.transferUrl
                    $transferHash = [string] $fileEntry.transferSha256
                    $transferSizeBytes = [int64] $fileEntry.transferSizeBytes
                }
                elseif (-not [string]::IsNullOrWhiteSpace($compression)) {
                    throw "Unsupported update payload compression: $compression"
                }

                $fileUrl = Resolve-UpdateUrl -BaseUrl $filesManifestUrl -Value $transferUrlValue
                $stagedPath = Resolve-InstallPath -RootDir $payloadDir -RelativePath $relativePath
                $stagedParent = Split-Path -Path $stagedPath -Parent
                if (-not [string]::IsNullOrWhiteSpace($stagedParent)) {
                    New-Item -Path $stagedParent -ItemType Directory -Force | Out-Null
                }

                Write-UpdateLog -Message "Downloading changed file: $relativePath" -LogPath $mainLogPath
                $cacheKey = if (-not [string]::IsNullOrWhiteSpace($transferHash)) { $transferHash.ToLowerInvariant() } else { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($relativePath)).Replace('/', '_') }
                $cachedPath = Join-Path -Path $persistentCacheRoot -ChildPath $cacheKey
                Invoke-ResumableUpdateWebRequest -Uri $fileUrl -OutFile $cachedPath -ExpectedSizeBytes $transferSizeBytes -ExpectedSha256 $transferHash -AggregateCompletedBytes $completedDownloadBytes -TotalDownloadBytes $totalDownloadBytes
                if ($transferSizeBytes -gt 0) {
                    $completedDownloadBytes += $transferSizeBytes
                }
                if ($compression -eq 'gzip') {
                    Expand-VerifiedGzipUpdateFile -SourcePath $cachedPath -DestinationPath $stagedPath
                }
                else {
                    Copy-Item -LiteralPath $cachedPath -Destination $stagedPath -Force
                }
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
                $currentExe = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.exe'
                if (-not $NoStart -and (Test-Path -LiteralPath $currentExe -PathType Leaf)) {
                    Write-UpdateLog -Message 'No installation required. The current client and supervisor remain running.' -LogPath $mainLogPath
                }
                return
            }

            Write-UpdateLog -Message 'Stopping the supervisor before scheduling differential replacement.' -LogPath $mainLogPath
            Write-UpdateProgress -Status 'installing' -DownloadedBytes $totalDownloadBytes -TotalBytes $totalDownloadBytes -Message 'Download verified. Installing the client update.'
            Remove-ObsoleteLaunchRegistrations -TargetInstallDir $InstallDir -LogPath $mainLogPath
            Stop-ObsoleteInstallProcesses -TargetInstallDir $InstallDir -LogPath $mainLogPath
            Stop-SupervisorProcesses -TargetInstallDir $InstallDir
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
    $expectedHash = [string] $manifest.sha256
    $cachedZipPath = Join-Path -Path $persistentCacheRoot -ChildPath 'complete-package.zip'
    Write-UpdateProgress -Status 'downloading' -DownloadedBytes 0 -TotalBytes $declaredSizeBytes -Message 'Downloading the verified client package.'
    Invoke-ResumableUpdateWebRequest -Uri $zipUrl -OutFile $cachedZipPath -ExpectedSizeBytes $declaredSizeBytes -ExpectedSha256 $expectedHash -TotalDownloadBytes $declaredSizeBytes
    Copy-Item -LiteralPath $cachedZipPath -Destination $zipPath -Force

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

    Write-UpdateLog -Message 'Stopping the supervisor before scheduling package replacement.' -LogPath $mainLogPath
    Write-UpdateProgress -Status 'installing' -DownloadedBytes $declaredSizeBytes -TotalBytes $declaredSizeBytes -Message 'Download verified. Installing the client update.'
    Remove-ObsoleteLaunchRegistrations -TargetInstallDir $InstallDir -LogPath $mainLogPath
    Stop-ObsoleteInstallProcesses -TargetInstallDir $InstallDir -LogPath $mainLogPath
    Stop-SupervisorProcesses -TargetInstallDir $InstallDir
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
catch {
    Write-UpdateProgress -Status 'failed' -DownloadedBytes ([Math]::Max([int64]0, $script:LastUpdateProgressBytes)) -TotalBytes 0 -Message $_.Exception.Message
    Write-UpdateLog -Message "Updater failed: $($_.Exception.Message)" -LogPath $mainLogPath
    $currentExe = Join-Path -Path $InstallDir -ChildPath 'sync_windows_agent.exe'
    if (-not $NoStart -and (Test-Path -LiteralPath $currentExe -PathType Leaf)) {
        try {
            Write-UpdateLog -Message 'Attempting recovery relaunch of the current client.' -LogPath $mainLogPath
            Start-UpdatedClient -ExecutablePath $currentExe -InstallDir $InstallDir -LogPath $mainLogPath
        }
        catch {
            Write-UpdateLog -Message "Recovery relaunch failed: $($_.Exception.Message)" -LogPath $mainLogPath
        }
    }
    throw
}
finally {
    if (-not (Test-Path -LiteralPath (Join-Path -Path $workRoot -ChildPath 'finalize-update.ps1') -PathType Leaf)) {
        Write-UpdateLog -Message "Cleaning work root immediately: $workRoot" -LogPath $mainLogPath
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($updateMutexAcquired) {
        try {
            $updateMutex.ReleaseMutex() | Out-Null
        }
        catch {
        }
    }
    $updateMutex.Dispose()
}

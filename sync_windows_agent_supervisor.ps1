param(
    [string] $ManifestUrl = 'https://sync.velvet-leaf.com/client/latest.json',
    [ValidateRange(5, 3600)][int] $AgentCheckSeconds = 15,
    [ValidateRange(300, 86400)][int] $UpdateCheckSeconds = 600,
    [switch] $RunOnce,
    [switch] $SkipUpdate,
    [switch] $SkipAgentStart,
    [switch] $SkipObsoleteRetirement
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$scriptPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$installDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $scriptPath))
$executablePath = Join-Path -Path $installDir -ChildPath 'sync_windows_agent.exe'
$updateScriptPath = Join-Path -Path $installDir -ChildPath 'update.ps1'
$supervisorLogPath = Join-Path -Path $installDir -ChildPath 'sync_windows_agent_supervisor.log'
$requestLogPath = Join-Path -Path $installDir -ChildPath 'sync_windows_agent_update_requests.log'
$userStoppedMarkerPath = Join-Path -Path $installDir -ChildPath 'sync_windows_agent.user-stopped'
$requiredRuntimePaths = @(
    $executablePath,
    (Join-Path -Path $installDir -ChildPath 'flutter_windows.dll'),
    (Join-Path -Path $installDir -ChildPath 'data\app.so'),
    (Join-Path -Path $installDir -ChildPath 'data\icudtl.dat')
)
$lastIncompleteInstallSummary = ''

if ($env:SYNC_WINDOWS_AGENT_SUPERVISOR_SKIP_UPDATE -eq '1') {
    $SkipUpdate = $true
}
if ($env:SYNC_WINDOWS_AGENT_SUPERVISOR_SKIP_OBSOLETE_RETIREMENT -eq '1') {
    $SkipObsoleteRetirement = $true
}

function Write-SupervisorLog {
    param([Parameter(Mandatory = $true)][string] $Message)

    try {
        $timestamp = [DateTime]::UtcNow.ToString('o')
        Add-Content -LiteralPath $supervisorLogPath -Value "[$timestamp] $Message" -Encoding UTF8
    }
    catch {
    }
}

function Write-RequestLog {
    param([Parameter(Mandatory = $true)][string] $Message)

    try {
        $timestamp = [DateTime]::UtcNow.ToString('o')
        Add-Content -LiteralPath $requestLogPath -Value "[$timestamp] $Message" -Encoding UTF8
    }
    catch {
    }
}

function Get-InstallHash {
    param([Parameter(Mandatory = $true)][string] $Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        $hash = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16)
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-AgentProcesses {
    $targetPrefix = $installDir.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return @(Get-CimInstance Win32_Process -Filter "Name = 'sync_windows_agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
            ([System.IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith(
                $targetPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        })
}

function Get-MissingAgentRuntimePaths {
    return @($requiredRuntimePaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    })
}

function Remove-ObsoleteLaunchRegistrations {
    $retiredShortcuts = 0
    $retiredRunValues = 0
    $retiredTasks = 0

    # A copied executable cannot run without its adjacent Flutter runtime. An
    # old shortcut may therefore create a loader error before process-based
    # retirement can observe it. Inspect only launch registrations that name
    # this application and preserve the registration for this exact install.
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
                    if ($launchText.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
                    Remove-Item -LiteralPath $shortcutFile.FullName -Force -ErrorAction Stop
                    $retiredShortcuts += 1
                }
                catch {
                    Write-SupervisorLog "Could not retire obsolete startup shortcut $($shortcutFile.FullName): $($_.Exception.Message)"
                }
            }
        }
    }
    catch {
        Write-SupervisorLog "Could not inspect Windows startup shortcuts: $($_.Exception.Message)"
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
                if ($launchText.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
                Remove-ItemProperty -LiteralPath $runKeyPath -Name $property.Name -Force -ErrorAction Stop
                $retiredRunValues += 1
            }
        }
        catch {
            Write-SupervisorLog "Could not inspect Windows Run key ${runKeyPath}: $($_.Exception.Message)"
        }
    }

    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        foreach ($task in Get-ScheduledTask -ErrorAction SilentlyContinue) {
            try {
                $launchText = ((@($task.Actions) | ForEach-Object {
                    $executeProperty = $_.PSObject.Properties['Execute']
                    $argumentsProperty = $_.PSObject.Properties['Arguments']
                    if ($null -ne $executeProperty) {
                        $argumentsValue = if ($null -eq $argumentsProperty) { '' } else { [string] $argumentsProperty.Value }
                        "$([string] $executeProperty.Value) $argumentsValue"
                    }
                }) -join ' ')
                if ($launchText.IndexOf('sync_windows_agent', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                if ($launchText.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
                $retiredTasks += 1
            }
            catch {
                Write-SupervisorLog "Could not disable obsolete scheduled task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
            }
        }
    }

    if ($retiredShortcuts -gt 0 -or $retiredRunValues -gt 0 -or $retiredTasks -gt 0) {
        Write-SupervisorLog "Retired obsolete launch registrations. shortcuts=$retiredShortcuts runValues=$retiredRunValues scheduledTasks=$retiredTasks"
    }
}

function Stop-ObsoleteInstallProcesses {
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
            $_.CommandLine.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0
        })
    foreach ($process in $powershellProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        $stoppedSupervisors += 1
    }
    $legacyWatchdogPath = Join-Path -Path $installDir -ChildPath 'sync_windows_agent_watchdog.ps1'
    if (Test-Path -LiteralPath $legacyWatchdogPath -PathType Leaf) {
        Remove-Item -LiteralPath $legacyWatchdogPath -Force -ErrorAction SilentlyContinue
        Write-SupervisorLog "Removed obsolete generated watchdog script: $legacyWatchdogPath"
    }

    $targetPrefix = $installDir.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
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

    if ($stoppedSupervisors -gt 0 -or $stoppedAgents -gt 0) {
        Write-SupervisorLog "Retired obsolete installs. supervisors=$stoppedSupervisors agents=$stoppedAgents"
    }
}

function Ensure-AgentRunning {
    if (Test-Path -LiteralPath $userStoppedMarkerPath -PathType Leaf) {
        return
    }
    if ($SkipAgentStart -or @(Get-AgentProcesses).Count -gt 0) {
        return
    }
    $missingRuntimePaths = @(Get-MissingAgentRuntimePaths)
    if ($missingRuntimePaths.Count -gt 0) {
        $missingSummary = $missingRuntimePaths -join '; '
        if ($missingSummary -ne $script:lastIncompleteInstallSummary) {
            Write-SupervisorLog "Agent install is incomplete; launch suppressed until the complete portable folder is restored. missing=$missingSummary"
            $script:lastIncompleteInstallSummary = $missingSummary
        }
        return
    }
    $script:lastIncompleteInstallSummary = ''

    try {
        $process = Start-Process -FilePath $executablePath `
            -ArgumentList '--start-minimized' `
            -WorkingDirectory $installDir `
            -WindowStyle Minimized `
            -PassThru `
            -ErrorAction Stop
        Write-SupervisorLog "Started agent process pid=$($process.Id)."
    }
    catch {
        Write-SupervisorLog "Agent start failed; supervisor will retry: $($_.Exception.Message)"
    }
}

function Invoke-IndependentUpdateCheck {
    if ($SkipUpdate) {
        return
    }
    if (Test-Path -LiteralPath $userStoppedMarkerPath -PathType Leaf) {
        Write-RequestLog 'Update process skipped; the user closed the client and only a manual launch may resume it.'
        return
    }
    if (-not (Test-Path -LiteralPath $updateScriptPath -PathType Leaf)) {
        Write-RequestLog "Update check skipped; updater is unavailable: $updateScriptPath"
        return
    }

    $startedAt = [DateTime]::UtcNow
    Write-RequestLog "Update request started. manifest=$ManifestUrl"
    try {
        # Set hidden STARTUPINFO before the child is created. Supplying
        # -WindowStyle Hidden to a directly invoked console process can still
        # flash while that new PowerShell instance parses its arguments.
        $updateArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $updateScriptPath.Replace('"', '\"')),
            '-ManifestUrl', ('"{0}"' -f $ManifestUrl.Replace('"', '\"')),
            '-InstallDir', ('"{0}"' -f $installDir.Replace('"', '\"')),
            '-LauncherSupervisorProcessId', $PID
        )
        $updateProcess = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $updateArguments `
            -WorkingDirectory $installDir `
            -WindowStyle Hidden `
            -Wait `
            -PassThru `
            -ErrorAction Stop
        $exitCode = $updateProcess.ExitCode
        $elapsedMs = [Math]::Round(([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
        Write-RequestLog "Update request completed. exitCode=$exitCode elapsedMs=$elapsedMs"
    }
    catch {
        $elapsedMs = [Math]::Round(([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
        Write-RequestLog "Update request failed. elapsedMs=$elapsedMs error=$($_.Exception.Message)"
    }
}

$mutexName = 'Local\SqlSyncAgentSupervisor_' + (Get-InstallHash -Value $installDir)
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref] $createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    if (-not $SkipObsoleteRetirement) {
        Remove-ObsoleteLaunchRegistrations
        Stop-ObsoleteInstallProcesses
    }
    Write-SupervisorLog "Supervisor started. pid=$PID install=$installDir"
    Invoke-IndependentUpdateCheck
    Ensure-AgentRunning
    if ($RunOnce) {
        exit 0
    }

    $nextUpdateCheck = [DateTime]::UtcNow.AddSeconds($UpdateCheckSeconds)
    while ($true) {
        Start-Sleep -Seconds $AgentCheckSeconds
        if (-not $SkipObsoleteRetirement) {
            Remove-ObsoleteLaunchRegistrations
            Stop-ObsoleteInstallProcesses
        }
        Ensure-AgentRunning
        if ([DateTime]::UtcNow -ge $nextUpdateCheck) {
            Invoke-IndependentUpdateCheck
            $nextUpdateCheck = [DateTime]::UtcNow.AddSeconds($UpdateCheckSeconds)
        }
    }
}
finally {
    Write-SupervisorLog "Supervisor stopped. pid=$PID"
    try {
        $mutex.ReleaseMutex() | Out-Null
    }
    catch {
    }
    $mutex.Dispose()
}

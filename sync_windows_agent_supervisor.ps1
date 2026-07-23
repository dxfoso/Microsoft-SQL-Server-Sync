param(
    [string] $ManifestUrl = 'https://sync.velvet-leaf.com/client/latest.json',
    [ValidateRange(5, 3600)][int] $AgentCheckSeconds = 15,
    [ValidateRange(30, 86400)][int] $UpdateCheckSeconds = 300,
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
    if ($SkipAgentStart -or @(Get-AgentProcesses).Count -gt 0) {
        return
    }
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        Write-SupervisorLog "Agent executable is unavailable; supervisor remains active: $executablePath"
        return
    }

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
    if (-not (Test-Path -LiteralPath $updateScriptPath -PathType Leaf)) {
        Write-RequestLog "Update check skipped; updater is unavailable: $updateScriptPath"
        return
    }

    $startedAt = [DateTime]::UtcNow
    Write-RequestLog "Update request started. manifest=$ManifestUrl"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
            -File $updateScriptPath `
            -ManifestUrl $ManifestUrl `
            -InstallDir $installDir
        $exitCode = $LASTEXITCODE
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

param(
    [string] $ProjectPath = "$PSScriptRoot\sync_windows_agent",
    [string] $Device = "windows",
    [string] $BackendBaseUrl = "https://sync.velvet-leaf.com/call",
    [switch] $SkipGet,
    [bool] $AutoRestart = $true,
    [int] $DebounceMs = 900
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'scripts\windows_agent_build.ps1')

Initialize-WindowsAgentBuildEnvironment

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter is not installed or not available in PATH."
}

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Could not find project directory: $ProjectPath"
}

$mainDart = Join-Path -Path $ProjectPath -ChildPath "lib\main.dart"
if (-not (Test-Path -LiteralPath $mainDart)) {
    throw "This folder is not a Flutter app. Missing lib\main.dart in $ProjectPath"
}

$flutterProcess = $null
$appBinaryName = "sync_windows_agent.exe"

function New-DartDefineArgs {
    return New-WindowsAgentDartDefineArgs `
        -ProjectPath $ProjectPath `
        -BackendBaseUrl $BackendBaseUrl `
        -RepoRoot $PSScriptRoot
}

function Get-ChildProcessIds {
    param([int]$ProcessId)

    Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $ProcessId } |
        Select-Object -ExpandProperty ProcessId
}

function Stop-OrphanedAgentProcesses {
    $appBinaryPath = Join-Path $ProjectPath "build\windows\x64\runner\Debug\$appBinaryName"

    Get-Process -Name ($appBinaryName -replace '\.exe$', '') -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Path -or $_.Path -ieq $appBinaryPath } |
        ForEach-Object {
            Write-Host "Stopping leftover app process: $($_.Id)"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
}

function Stop-ProcessTree {
    param([int]$RootProcessId)

    foreach ($childId in (Get-ChildProcessIds -ProcessId $RootProcessId)) {
        Stop-ProcessTree -RootProcessId $childId
    }

    if (Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue) {
        try {
            Stop-Process -Id $RootProcessId -Force -ErrorAction Stop
        } catch {
            Write-Host "Unable to stop process $($RootProcessId): $($_.Exception.Message)"
        }
    }
}

function Start-App {
    Stop-OrphanedAgentProcesses
    Write-Host "Starting Windows desktop client: flutter run -d $Device"
    Write-Host "Backend URL: $BackendBaseUrl"
    $flutterArgs = @("run", "-d", $Device) + (New-DartDefineArgs)
    $script:flutterProcess = Start-Process -FilePath flutter `
        -ArgumentList $flutterArgs `
        -WorkingDirectory $ProjectPath `
        -PassThru `
        -NoNewWindow
}

function Stop-App {
    if ($null -eq $script:flutterProcess) {
        return
    }

    if ($script:flutterProcess.HasExited) {
        $script:flutterProcess = $null
        return
    }

    Write-Host "Stopping running app session (PID $($script:flutterProcess.Id))"
    Stop-ProcessTree -RootProcessId $script:flutterProcess.Id
    $script:flutterProcess = $null
}

function Restart-App {
    Stop-App
    Stop-OrphanedAgentProcesses
    Start-App
}

Push-Location $ProjectPath
try {
    if (-not $SkipGet) {
        flutter pub get
    }

    Start-App

    if (-not $AutoRestart) {
        Write-Host "Auto-restart disabled. Running a single session."
        $script:flutterProcess.WaitForExit()
        return
    }

    $watchPath = Join-Path $ProjectPath "lib"
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $watchPath
    $watcher.Filter = "*.dart"
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true

    Write-Host "Auto-restart is enabled. Watching: $watchPath"
    Write-Host "Press Ctrl+C to stop."

    try {
        $lastChange = Get-Date
        $shouldRestart = $false

        while ($true) {
            $change = $watcher.WaitForChanged(
                [System.IO.WatcherChangeTypes]::Changed -bor
                [System.IO.WatcherChangeTypes]::Created -bor
                [System.IO.WatcherChangeTypes]::Deleted -bor
                [System.IO.WatcherChangeTypes]::Renamed,
                300
            )

            if (-not $change.TimedOut) {
                $lastChange = Get-Date
                $shouldRestart = $true
                Write-Host "Detected file change: $($change.ChangeType) $($change.Name)"
            }

            if ($shouldRestart -and ((Get-Date) - $lastChange).TotalMilliseconds -gt $DebounceMs) {
                $shouldRestart = $false
                if ($script:flutterProcess -and -not $script:flutterProcess.HasExited) {
                    Write-Host "Restarting Flutter app..."
                    Restart-App
                }
            }
        }
    }
    finally {
        $watcher.Dispose()
        Stop-App
    }
}
finally {
    Pop-Location
}

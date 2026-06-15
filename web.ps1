param(
    [string] $FrontendPath = "$PSScriptRoot\frontend",
    [string] $BackendPath = "$PSScriptRoot\backend",
    [string] $BusinessConfigPath = "$PSScriptRoot\business\tru.json",
    [string] $Browser = "chrome",
    [switch] $SkipGet,
    [bool] $AutoRestart = $true,
    [int] $DebounceMs = 900
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter is not installed or not available in PATH."
}

if (-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
    throw "powershell.exe is not available in PATH."
}

if (-not (Test-Path -LiteralPath $FrontendPath)) {
    throw "Could not find frontend directory: $FrontendPath"
}

if (-not (Test-Path -LiteralPath $BackendPath)) {
    throw "Could not find backend directory: $BackendPath"
}

if (-not (Test-Path -LiteralPath $BusinessConfigPath)) {
    throw "Could not find TRU config file: $BusinessConfigPath"
}

$frontendMain = Join-Path -Path $FrontendPath -ChildPath "lib\main.dart"
if (-not (Test-Path -LiteralPath $frontendMain)) {
    throw "This folder is not a Flutter web app. Missing lib\main.dart in $FrontendPath"
}

$backendRun = Join-Path -Path $BackendPath -ChildPath "run.ps1"
$postgresRun = Join-Path -Path $BackendPath -ChildPath "create-postgresql.ps1"
if (-not (Test-Path -LiteralPath $backendRun)) {
    throw "Could not find backend launcher: $backendRun"
}
if (-not (Test-Path -LiteralPath $postgresRun)) {
    throw "Could not find PostgreSQL bootstrapper: $postgresRun"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$backendProcess = $null
$browserProcess = $null
$script:shouldRestart = $false
$script:lastChange = Get-Date

function Get-ChildProcessIds {
    param([int]$ProcessId)

    Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $ProcessId } |
        Select-Object -ExpandProperty ProcessId
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

function Stop-AppProcess {
    param([System.Diagnostics.Process] $Process)

    if ($null -eq $Process) {
        return
    }

    if ($Process.HasExited) {
        return
    }

    Stop-ProcessTree -RootProcessId $Process.Id
}

function Get-ConfigPort {
    param([string]$ConfigPath)

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $port = 9001
    if ($null -ne $config.port) {
        try {
            $port = [int]$config.port
        } catch {
            $port = 9001
        }
    }
    return $port
}

function Wait-BackendHealthy {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $healthUrl = "http://127.0.0.1:$Port/admin/health"

    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3
            if ($response.StatusCode -eq 200) {
                return $true
            }
        } catch {
            Start-Sleep -Milliseconds 1000
        }
    }

    return $false
}

function Start-LocalDatabase {
    Write-Host "Starting local Postgres for web mode..." -ForegroundColor Cyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $postgresRun --config-path $BusinessConfigPath
    if ($LASTEXITCODE -ne 0) {
        throw "Postgres bootstrap failed with exit code $LASTEXITCODE"
    }
}

function Start-Backend {
    $backendArgs = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $backendRun,
        '-Server',
        '-ConfigPath',
        $BusinessConfigPath
    )

    Write-Host "Starting local backend server..." -ForegroundColor Cyan
    return Start-Process -FilePath powershell.exe `
        -ArgumentList $backendArgs `
        -WorkingDirectory $BackendPath `
        -WindowStyle Hidden `
        -PassThru
}

function Start-BrowserApp {
    param([int]$BackendPort)

    $dartDefine = "BACKEND_BASE_URL=http://127.0.0.1:$BackendPort/call"
    $flutterArgs = @('run', '-d', $Browser, '--dart-define', $dartDefine)

    if (-not $SkipGet) {
        flutter pub get
    }

    Write-Host "Starting web app in browser: flutter run -d $Browser" -ForegroundColor Cyan
    return Start-Process -FilePath flutter `
        -ArgumentList $flutterArgs `
        -WorkingDirectory $FrontendPath `
        -WindowStyle Hidden `
        -PassThru
}

function Start-Stack {
    Start-LocalDatabase

    $backendPort = Get-ConfigPort -ConfigPath $BusinessConfigPath
    $script:backendPort = $backendPort

    $script:backendProcess = Start-Backend
    if (-not (Wait-BackendHealthy -Port $backendPort)) {
        Stop-AppProcess -Process $script:backendProcess
        $script:backendProcess = $null
        throw "Backend did not become healthy on port $backendPort."
    }

    $script:browserProcess = Start-BrowserApp -BackendPort $backendPort
}

function Restart-Stack {
    Write-Host "Restarting local web stack..." -ForegroundColor Yellow
    Stop-AppProcess -Process $script:browserProcess
    Stop-AppProcess -Process $script:backendProcess
    $script:browserProcess = $null
    $script:backendProcess = $null
    Start-Stack
}

function New-Watcher {
    param(
        [string]$Path,
        [string]$Filter,
        [bool]$IncludeSubdirectories = $false
    )

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $Path
    $watcher.Filter = $Filter
    $watcher.IncludeSubdirectories = $IncludeSubdirectories
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
        [System.IO.NotifyFilters]::LastWrite -bor
        [System.IO.NotifyFilters]::CreationTime
    $watcher.EnableRaisingEvents = $true
    return $watcher
}

function Test-RestartRelevantPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalized = $Path.Replace('/', '\').ToLowerInvariant()

    if ($normalized.StartsWith((Join-Path $FrontendPath 'lib').Replace('/', '\').ToLowerInvariant()) -and $normalized.EndsWith('.dart')) {
        return $true
    }

    if ($normalized -eq (Join-Path $FrontendPath 'pubspec.yaml').Replace('/', '\').ToLowerInvariant()) {
        return $true
    }

    if ($normalized -eq (Join-Path $FrontendPath 'pubspec.lock').Replace('/', '\').ToLowerInvariant()) {
        return $true
    }

    $backendSrc = Join-Path $BackendPath 'server\src'
    if ($normalized.StartsWith($backendSrc.Replace('/', '\').ToLowerInvariant()) -and $normalized.EndsWith('.rs')) {
        return $true
    }

    if ($normalized -eq (Join-Path $BackendPath 'server\Cargo.toml').Replace('/', '\').ToLowerInvariant()) {
        return $true
    }

    if ($normalized -eq (Join-Path $BackendPath 'server\Cargo.lock').Replace('/', '\').ToLowerInvariant()) {
        return $true
    }

    if ($normalized.StartsWith((Join-Path $repoRoot 'business').Replace('/', '\').ToLowerInvariant()) -and $normalized.EndsWith('.tru')) {
        return $true
    }

    return $false
}

function Register-Watcher {
    param(
        [System.IO.FileSystemWatcher]$Watcher,
        [string]$Name
    )

    foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed')) {
        Register-ObjectEvent -InputObject $Watcher -EventName $eventName -SourceIdentifier "$Name.$eventName" -Action {
            $path = $Event.SourceEventArgs.FullPath
            if (Test-RestartRelevantPath -Path $path) {
                $script:shouldRestart = $true
                $script:lastChange = Get-Date
                Write-Host "Detected file change: $path" -ForegroundColor DarkYellow
            }
        } | Out-Null
    }
}

Push-Location $repoRoot
try {
    Start-Stack

    if (-not $AutoRestart) {
        Write-Host "Auto-restart disabled. Press Ctrl+C to stop." -ForegroundColor Yellow
        while ($true) {
            Start-Sleep -Seconds 1
            if ($null -ne $script:backendProcess -and $script:backendProcess.HasExited) {
                throw "Backend process exited unexpectedly."
            }
            if ($null -ne $script:browserProcess -and $script:browserProcess.HasExited) {
                throw "Browser process exited unexpectedly."
            }
        }
    }

    $watchers = @(
        New-Watcher -Path (Join-Path $FrontendPath 'lib') -Filter '*.dart' -IncludeSubdirectories $true
        New-Watcher -Path $FrontendPath -Filter 'pubspec.yaml'
        New-Watcher -Path $FrontendPath -Filter 'pubspec.lock'
        New-Watcher -Path (Join-Path $BackendPath 'server\src') -Filter '*.rs' -IncludeSubdirectories $true
        New-Watcher -Path (Join-Path $BackendPath 'server') -Filter 'Cargo.toml'
        New-Watcher -Path (Join-Path $BackendPath 'server') -Filter 'Cargo.lock'
        New-Watcher -Path (Join-Path $repoRoot 'business') -Filter '*.tru' -IncludeSubdirectories $true
    )

    foreach ($index in 0..($watchers.Count - 1)) {
        Register-Watcher -Watcher $watchers[$index] -Name "watcher$index"
    }

    Write-Host "Auto-restart is enabled. Watching frontend, backend, and business source files." -ForegroundColor Green
    Write-Host "Press Ctrl+C to stop." -ForegroundColor Green

    try {
        while ($true) {
            Start-Sleep -Milliseconds 250

            if ($null -ne $script:backendProcess -and $script:backendProcess.HasExited) {
                throw "Backend process exited unexpectedly."
            }

            if ($null -ne $script:browserProcess -and $script:browserProcess.HasExited) {
                throw "Browser process exited unexpectedly."
            }

            if ($script:shouldRestart -and ((Get-Date) - $script:lastChange).TotalMilliseconds -ge $DebounceMs) {
                $script:shouldRestart = $false
                Restart-Stack
            }
        }
    }
    finally {
        foreach ($watcher in $watchers) {
            if ($null -ne $watcher) {
                $watcher.Dispose()
            }
        }

        Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like 'watcher*' } | ForEach-Object {
            Unregister-Event -SourceIdentifier $_.SourceIdentifier -ErrorAction SilentlyContinue
        }
        Remove-Event -SourceIdentifier * -ErrorAction SilentlyContinue

        Stop-AppProcess -Process $script:browserProcess
        Stop-AppProcess -Process $script:backendProcess
    }
}
finally {
    Pop-Location
}

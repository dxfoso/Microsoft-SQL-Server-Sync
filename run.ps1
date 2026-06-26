param(
    [string] $FrontendPath = "$PSScriptRoot\frontend",
    [string] $DesktopPath = "$PSScriptRoot\sync_windows_agent",
    [string] $BackendPath = "$PSScriptRoot\backend",
    [string] $BusinessConfigPath = "$PSScriptRoot\business\tru.json",
    [string] $Browser = "chrome",
    [string] $DesktopDevice = "windows",
    [switch] $SkipGet,
    [switch] $RestartDb,
    [bool] $AutoRestart = $true,
    [int] $DebounceMs = 900
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'scripts\windows_agent_build.ps1')

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter is not installed or not available in PATH."
}

if (-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
    throw "powershell.exe is not available in PATH."
}

foreach ($path in @($FrontendPath, $DesktopPath, $BackendPath, $BusinessConfigPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Could not find required path: $path"
    }
}

$frontendMain = Join-Path -Path $FrontendPath -ChildPath "lib\main.dart"
$desktopMain = Join-Path -Path $DesktopPath -ChildPath "lib\main.dart"
if (-not (Test-Path -LiteralPath $frontendMain)) {
    throw "This folder is not a Flutter web app. Missing lib\main.dart in $FrontendPath"
}
if (-not (Test-Path -LiteralPath $desktopMain)) {
    throw "This folder is not a Flutter desktop app. Missing lib\main.dart in $DesktopPath"
}

$backendRun = Join-Path -Path $BackendPath -ChildPath "run.ps1"
$postgresRun = Join-Path -Path $BackendPath -ChildPath "create-postgresql.ps1"
if (-not (Test-Path -LiteralPath $backendRun)) {
    throw "Could not find backend launcher: $backendRun"
}
if (-not (Test-Path -LiteralPath $postgresRun)) {
    throw "Could not find PostgreSQL bootstrapper: $postgresRun"
}

$repoRoot = $PSScriptRoot
$script:backendProcess = $null
$script:webProcess = $null
$script:webBrowserProcess = $null
$script:webUserDataDir = Join-Path -Path $repoRoot -ChildPath '.codex-run\web-browser'
$script:webPort = $null
$script:desktopProcess = $null
$script:restartWeb = $false
$script:restartDesktop = $false
$script:restartBackend = $false
$script:lastChange = Get-Date
$script:backendUnavailableSince = $null

function New-DartDefineArgs {
    param(
        [string]$ProjectPath,
        [string]$BackendBaseUrl
    )

    return New-WindowsAgentDartDefineArgs `
        -ProjectPath $ProjectPath `
        -BackendBaseUrl $BackendBaseUrl `
        -RepoRoot $repoRoot
}

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

function Remove-DirectoryIfExists {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "Unable to remove directory ${Path}: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Stop-PortListeners {
    param([int]$Port)

    $connections = @()
    try {
        $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    } catch {
        return
    }

    foreach ($processId in @($connections | Select-Object -ExpandProperty OwningProcess -Unique)) {
        if ($processId -le 0) {
            continue
        }
        Write-Host "Stopping process $processId listening on backend port $Port..." -ForegroundColor Yellow
        Stop-ProcessTree -RootProcessId $processId
    }
}

function Get-RepoDesktopAppProcesses {
    $exePath = (Join-Path $DesktopPath 'build\windows\x64\runner\Debug\sync_windows_agent.exe').ToLowerInvariant()
    $name = 'sync_windows_agent.exe'

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq $name -and
            $_.ExecutablePath -and
            $_.ExecutablePath.ToLowerInvariant() -eq $exePath
        })
}

function Get-RepoDesktopAppProcess {
    $processes = @(Get-RepoDesktopAppProcesses)
    if ($processes.Count -eq 0) {
        return $null
    }
    return Get-Process -Id $processes[0].ProcessId -ErrorAction SilentlyContinue
}

function Stop-RepoDesktopAppProcesses {
    foreach ($processInfo in (Get-RepoDesktopAppProcesses)) {
        if ($null -eq $processInfo.ProcessId -or $processInfo.ProcessId -le 0) {
            continue
        }
        Write-Host "Stopping stale desktop app process $($processInfo.ProcessId)..." -ForegroundColor Yellow
        Stop-ProcessTree -RootProcessId $processInfo.ProcessId
    }
}

function Get-ConfigPort {
    param([string]$ConfigPath)

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $port = 6006
    if ($null -ne $config.port) {
        try {
            $port = [int]$config.port
        } catch {
            $port = 6006
        }
    }
    return $port
}

function Get-DatabaseContainerName {
    param([string]$ConfigPath)

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($null -ne $config.db -and $null -ne $config.db.container) {
        return [string]$config.db.container
    }
    if ($null -ne $config.settings -and $null -ne $config.settings.db -and $null -ne $config.settings.db.container) {
        return [string]$config.settings.db.container
    }
    return ""
}

function Get-DatabaseName {
    param([string]$ConfigPath)

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($null -ne $config.db -and $null -ne $config.db.database) {
        return [string]$config.db.database
    }
    if ($null -ne $config.settings -and $null -ne $config.settings.db -and $null -ne $config.settings.db.database) {
        return [string]$config.settings.db.database
    }
    return "tru"
}

function Get-DatabasePort {
    param([string]$ConfigPath)

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($null -ne $config.db -and $null -ne $config.db.port) {
        try {
            return [int]$config.db.port
        } catch {
            return 5432
        }
    }
    if ($null -ne $config.settings -and $null -ne $config.settings.db -and $null -ne $config.settings.db.port) {
        try {
            return [int]$config.settings.db.port
        } catch {
            return 5432
        }
    }
    return 5432
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 600
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($asyncResult)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-BackendAvailable {
    param([int]$Port)

    if (Test-TcpPort -HostName '127.0.0.1' -Port $Port) {
        return $true
    }

    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/admin/health" -UseBasicParsing -TimeoutSec 2
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-RepoBackendServerProcess {
    $targetRoot = (Join-Path -Path $BackendPath -ChildPath 'server\target').Replace('/', '\').ToLowerInvariant()
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'tru_server.exe'" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        if ($null -eq $process -or [string]::IsNullOrWhiteSpace($process.ExecutablePath)) {
            continue
        }

        $executablePath = ([string]$process.ExecutablePath).Replace('/', '\').ToLowerInvariant()
        if ($executablePath.StartsWith($targetRoot)) {
            return Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        }
    }

    return $null
}

function Wait-RepoBackendServerProcess {
    param([int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $serverProcess = Get-RepoBackendServerProcess
        if ($null -ne $serverProcess) {
            return $serverProcess
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Restart-DatabaseContainer {
    param([string]$ConfigPath)

    $containerName = Get-DatabaseContainerName -ConfigPath $ConfigPath
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        return
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is not installed or not available in PATH."
    }

    Write-Host "Restarting local Postgres container: $containerName" -ForegroundColor Cyan
    & docker restart $containerName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Postgres container restart failed with exit code $LASTEXITCODE"
    }

    $databaseName = Get-DatabaseName -ConfigPath $ConfigPath
    for ($i = 0; $i -lt 60; $i += 1) {
        & docker exec $containerName pg_isready -U tru -d $databaseName | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds 1
    }

    throw "Postgres container did not become ready after restart."
}

function Test-DatabaseContainerReady {
    param([string]$ConfigPath)

    $databasePort = Get-DatabasePort -ConfigPath $ConfigPath
    if (Test-TcpPort -HostName '127.0.0.1' -Port $databasePort) {
        return $true
    }

    $containerName = Get-DatabaseContainerName -ConfigPath $ConfigPath
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        return $false
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $state = (& docker inspect -f '{{.State.Status}}' $containerName 2>$null)
        if ($LASTEXITCODE -ne 0 -or $state.Trim().ToLowerInvariant() -ne 'running') {
            return $false
        }

        $databaseName = Get-DatabaseName -ConfigPath $ConfigPath
        & docker exec $containerName pg_isready -U tru -d $databaseName 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Wait-BackendHealthy {
    param(
        [int]$Port,
        [System.Diagnostics.Process]$Process = $null,
        [int]$TimeoutSeconds = 900
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
            if ($null -ne $Process -and $Process.HasExited -and $null -eq (Get-RepoBackendServerProcess)) {
                return $false
            }
        }

        Start-Sleep -Milliseconds 1000
    }

    return $false
}

function Start-LocalDatabase {
    if (-not $RestartDb -and (Test-DatabaseContainerReady -ConfigPath $BusinessConfigPath)) {
        $containerName = Get-DatabaseContainerName -ConfigPath $BusinessConfigPath
        Write-Host "Local Postgres is already ready: $containerName" -ForegroundColor Cyan
        return
    }

    if ($RestartDb) {
        Write-Host "Restarting local Postgres for run mode..." -ForegroundColor Cyan
    } else {
        Write-Host "Starting local Postgres for run mode..." -ForegroundColor Cyan
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $postgresRun --config-path $BusinessConfigPath
    if ($LASTEXITCODE -ne 0) {
        throw "Postgres bootstrap failed with exit code $LASTEXITCODE"
    }

    if ($RestartDb) {
        Restart-DatabaseContainer -ConfigPath $BusinessConfigPath
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

function Start-WebApp {
    param([int]$BackendPort)

    if (-not $SkipGet) {
        Push-Location $FrontendPath
        try {
            flutter pub get
        } finally {
            Pop-Location
        }
    }

    $backendBaseUrl = "http://127.0.0.1:$BackendPort/call"
    $script:webPort = Get-FreeTcpPort
    $flutterArgs = @(
        'run',
        '-d',
        'web-server',
        '--web-hostname',
        '127.0.0.1',
        '--web-port',
        $script:webPort
    ) + (New-DartDefineArgs -ProjectPath $FrontendPath -BackendBaseUrl $backendBaseUrl)

    Write-Host "Starting web app on local server: flutter run -d web-server --web-port $($script:webPort)" -ForegroundColor Cyan
    return Start-Process -FilePath flutter `
        -ArgumentList $flutterArgs `
        -WorkingDirectory $FrontendPath `
        -WindowStyle Hidden `
        -PassThru
}

function Get-BrowserExecutablePath {
    param([string]$BrowserName)

    $normalized = $BrowserName.Trim().ToLowerInvariant()
    $candidates = @()
    switch ($normalized) {
        'chrome' {
            $candidates = @(
                "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
            )
        }
        'edge' {
            $candidates = @(
                "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
            )
        }
        default {
            $candidates = @($BrowserName)
        }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
        try {
            $command = Get-Command $candidate -ErrorAction Stop
            if ($null -ne $command.Source) {
                return $command.Source
            }
        } catch {
        }
    }

    return $null
}

function Wait-WebAppReady {
    param(
        [int]$Port,
        [System.Diagnostics.Process]$Process = $null,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $url = "http://127.0.0.1:$Port"

    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return $true
            }
        } catch {
            if ($null -ne $Process -and $Process.HasExited) {
                return $false
            }
        }

        Start-Sleep -Milliseconds 1000
    }

    return $false
}

function Start-WebBrowser {
    param([int]$Port)

    $browserPath = Get-BrowserExecutablePath -BrowserName $Browser
    if ($null -eq $browserPath) {
        Write-Host "Could not resolve browser executable for $Browser. Skipping browser launch." -ForegroundColor DarkYellow
        return $null
    }

    Remove-DirectoryIfExists -Path $script:webUserDataDir
    New-Item -ItemType Directory -Path $script:webUserDataDir -Force | Out-Null

    $url = "http://127.0.0.1:$Port"
    $browserArgs = @(
        "--user-data-dir=$script:webUserDataDir",
        '--new-window',
        "--app=$url"
    )

    Write-Host "Opening web app in dedicated $Browser window: $url" -ForegroundColor Green
    return Start-Process -FilePath $browserPath `
        -ArgumentList $browserArgs `
        -WorkingDirectory $repoRoot `
        -WindowStyle Normal `
        -PassThru
}

function Start-DesktopApp {
    param([int]$BackendPort)

    if (-not $SkipGet) {
        Push-Location $DesktopPath
        try {
            flutter pub get
        } finally {
            Pop-Location
        }
    }

    $backendBaseUrl = "http://127.0.0.1:$BackendPort/call"
    $flutterArgs = @('run', '-d', $DesktopDevice) + (New-DartDefineArgs -ProjectPath $DesktopPath -BackendBaseUrl $backendBaseUrl)

    Write-Host "Starting Windows desktop client: flutter run -d $DesktopDevice" -ForegroundColor Cyan
    Write-Host "Desktop API URL: $backendBaseUrl" -ForegroundColor Green
    Stop-RepoDesktopAppProcesses
    return Start-Process -FilePath flutter `
        -ArgumentList $flutterArgs `
        -WorkingDirectory $DesktopPath `
        -WindowStyle Hidden `
        -PassThru
}

function Start-Stack {
    Start-LocalDatabase

    $backendPort = Get-ConfigPort -ConfigPath $BusinessConfigPath
    $script:backendPort = $backendPort
    $script:serverUrl = "http://127.0.0.1:$backendPort"
    $script:clientUrl = "http://127.0.0.1:$backendPort/call"

    Stop-PortListeners -Port $backendPort
    $script:backendProcess = Start-Backend
    if (-not (Wait-BackendHealthy -Port $backendPort -Process $script:backendProcess)) {
        Stop-AppProcess -Process $script:backendProcess
        $script:backendProcess = $null
        throw "Backend did not become healthy on port $backendPort."
    }

    $serverProcess = Wait-RepoBackendServerProcess
    if ($null -ne $serverProcess) {
        $script:backendProcess = $serverProcess
    }

    Write-Host "Local server URL: " -NoNewline -ForegroundColor DarkCyan
    Write-Host $script:serverUrl -ForegroundColor Cyan
    Write-Host "Local API URL: " -NoNewline -ForegroundColor DarkGreen
    Write-Host $script:clientUrl -ForegroundColor Green

    $script:webProcess = Start-WebApp -BackendPort $backendPort
    if (-not (Wait-WebAppReady -Port $script:webPort -Process $script:webProcess)) {
        Stop-AppProcess -Process $script:webProcess
        $script:webProcess = $null
        throw "Web app did not become ready on port $($script:webPort)."
    }
    $script:webBrowserProcess = Start-WebBrowser -Port $script:webPort
    Write-Host "Web app started on port $($script:webPort)." -ForegroundColor Magenta

    $script:desktopProcess = Start-DesktopApp -BackendPort $backendPort
    Write-Host "Desktop app started in $DesktopDevice." -ForegroundColor Magenta
}

function Restart-FullStack {
    Write-Host "Restarting full local stack..." -ForegroundColor Yellow
    Stop-AppProcess -Process $script:webBrowserProcess
    Stop-AppProcess -Process $script:webProcess
    Stop-AppProcess -Process $script:desktopProcess
    Stop-AppProcess -Process $script:backendProcess
    Remove-DirectoryIfExists -Path $script:webUserDataDir
    $script:webBrowserProcess = $null
    $script:webProcess = $null
    $script:desktopProcess = $null
    $script:backendProcess = $null
    $script:backendUnavailableSince = $null
    $script:restartWeb = $false
    $script:restartDesktop = $false
    $script:restartBackend = $false
    Start-Stack
}

function Restart-WebApp {
    Write-Host "Restarting web app..." -ForegroundColor Yellow
    Stop-AppProcess -Process $script:webBrowserProcess
    Stop-AppProcess -Process $script:webProcess
    Remove-DirectoryIfExists -Path $script:webUserDataDir
    $script:webProcess = Start-WebApp -BackendPort $script:backendPort
    if (-not (Wait-WebAppReady -Port $script:webPort -Process $script:webProcess)) {
        Stop-AppProcess -Process $script:webProcess
        $script:webProcess = $null
        throw "Web app did not become ready on port $($script:webPort)."
    }
    $script:webBrowserProcess = Start-WebBrowser -Port $script:webPort
    $script:restartWeb = $false
}

function Restart-DesktopApp {
    Write-Host "Restarting desktop app..." -ForegroundColor Yellow
    Stop-AppProcess -Process $script:desktopProcess
    $script:desktopProcess = Start-DesktopApp -BackendPort $script:backendPort
    $script:restartDesktop = $false
}

function Get-RestartScopeForPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $normalized = $Path.Replace('/', '\').ToLowerInvariant()
    $frontendRoot = $FrontendPath.Replace('/', '\').ToLowerInvariant()
    $desktopRoot = $DesktopPath.Replace('/', '\').ToLowerInvariant()
    $backendRoot = $BackendPath.Replace('/', '\').ToLowerInvariant()
    $businessRoot = (Join-Path $repoRoot 'business').Replace('/', '\').ToLowerInvariant()

    if ($normalized.StartsWith((Join-Path $frontendRoot 'lib').ToLowerInvariant()) -and $normalized.EndsWith('.dart')) {
        return 'web'
    }
    if ($normalized -eq (Join-Path $frontendRoot 'pubspec.yaml').ToLowerInvariant()) {
        return 'web'
    }
    if ($normalized -eq (Join-Path $frontendRoot 'pubspec.lock').ToLowerInvariant()) {
        return 'web'
    }

    if ($normalized.StartsWith((Join-Path $desktopRoot 'lib').ToLowerInvariant()) -and $normalized.EndsWith('.dart')) {
        return 'desktop'
    }
    if ($normalized -eq (Join-Path $desktopRoot 'pubspec.yaml').ToLowerInvariant()) {
        return 'desktop'
    }
    if ($normalized -eq (Join-Path $desktopRoot 'pubspec.lock').ToLowerInvariant()) {
        return 'desktop'
    }

    if ($normalized.StartsWith((Join-Path $backendRoot 'server\src').ToLowerInvariant()) -and $normalized.EndsWith('.rs')) {
        return 'backend'
    }
    if ($normalized -eq (Join-Path $backendRoot 'server\Cargo.toml').ToLowerInvariant()) {
        return 'backend'
    }
    if ($normalized -eq (Join-Path $backendRoot 'server\Cargo.lock').ToLowerInvariant()) {
        return 'backend'
    }
    if ($normalized -eq (Join-Path $backendRoot 'run.ps1').ToLowerInvariant()) {
        return 'backend'
    }
    if ($normalized -eq (Join-Path $backendRoot 'create-postgresql.ps1').ToLowerInvariant()) {
        return 'backend'
    }

    if ($normalized.StartsWith($businessRoot) -and $normalized.EndsWith('.tru')) {
        return 'backend'
    }

    return $null
}

function Register-Watcher {
    param(
        [System.IO.FileSystemWatcher]$Watcher,
        [string]$Name
    )

    foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed')) {
        Register-ObjectEvent -InputObject $Watcher -EventName $eventName -SourceIdentifier "$Name.$eventName" -Action {
            $path = $Event.SourceEventArgs.FullPath
            $scope = Get-RestartScopeForPath -Path $path
            if ($null -ne $scope) {
                switch ($scope) {
                    'web' { $script:restartWeb = $true }
                    'desktop' { $script:restartDesktop = $true }
                    'backend' { $script:restartBackend = $true }
                }
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
            $serverProcess = Get-RepoBackendServerProcess
            if ($null -eq $serverProcess -and -not (Test-TcpPort -HostName '127.0.0.1' -Port $script:backendPort)) {
                throw "Backend process exited unexpectedly."
            }
            if ($null -ne $serverProcess) {
                $script:backendProcess = $serverProcess
            }
            if ($null -ne $script:webProcess -and $script:webProcess.HasExited) {
                throw "Web process exited unexpectedly."
            }
            if ($null -ne $script:desktopProcess -and $script:desktopProcess.HasExited) {
                throw "Desktop process exited unexpectedly."
            }
        }
    }

    $watchers = @(
        New-Object System.IO.FileSystemWatcher
        New-Object System.IO.FileSystemWatcher
        New-Object System.IO.FileSystemWatcher
        New-Object System.IO.FileSystemWatcher
        New-Object System.IO.FileSystemWatcher
        New-Object System.IO.FileSystemWatcher
        New-Object System.IO.FileSystemWatcher
    )

    $watchers[0].Path = Join-Path $FrontendPath 'lib'
    $watchers[0].Filter = '*.dart'
    $watchers[0].IncludeSubdirectories = $true
    $watchers[1].Path = $FrontendPath
    $watchers[1].Filter = 'pubspec.yaml'
    $watchers[2].Path = $FrontendPath
    $watchers[2].Filter = 'pubspec.lock'
    $watchers[3].Path = Join-Path $DesktopPath 'lib'
    $watchers[3].Filter = '*.dart'
    $watchers[3].IncludeSubdirectories = $true
    $watchers[4].Path = $DesktopPath
    $watchers[4].Filter = 'pubspec.yaml'
    $watchers[5].Path = $DesktopPath
    $watchers[5].Filter = 'pubspec.lock'
    $watchers[6].Path = $repoRoot
    $watchers[6].Filter = '*.tru'
    $watchers[6].IncludeSubdirectories = $true

    foreach ($watcher in $watchers) {
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
            [System.IO.NotifyFilters]::LastWrite -bor
            [System.IO.NotifyFilters]::CreationTime
        $watcher.EnableRaisingEvents = $true
    }

    foreach ($index in 0..($watchers.Count - 1)) {
        Register-Watcher -Watcher $watchers[$index] -Name "watcher$index"
    }

    Write-Host "Auto-restart is enabled. Watching frontend, desktop, backend, and business source files." -ForegroundColor Green
    Write-Host "Press Ctrl+C to stop." -ForegroundColor Green

    try {
        while ($true) {
            Start-Sleep -Milliseconds 250

            $serverProcess = Get-RepoBackendServerProcess
            $backendAvailable = Test-BackendAvailable -Port $script:backendPort
            if ($null -eq $serverProcess -and -not $backendAvailable) {
                if ($null -eq $script:backendUnavailableSince) {
                    $script:backendUnavailableSince = Get-Date
                }
                if (((Get-Date) - $script:backendUnavailableSince).TotalSeconds -ge 3) {
                    Write-Host "Restart reason: backend listener is down." -ForegroundColor Red
                    Restart-FullStack
                    continue
                }
            } else {
                $script:backendUnavailableSince = $null
            }
            if ($null -ne $serverProcess) {
                $script:backendProcess = $serverProcess
            }

            if ($null -ne $script:desktopProcess -and $script:desktopProcess.HasExited) {
                $desktopAppProcess = Get-RepoDesktopAppProcess
                if ($null -ne $desktopAppProcess) {
                    $script:desktopProcess = $desktopAppProcess
                } else {
                    Write-Host "Restart reason: desktop launcher process exited and no desktop app process was found." -ForegroundColor Red
                    Restart-DesktopApp
                }
                continue
            }

            if ($script:restartBackend -and ((Get-Date) - $script:lastChange).TotalMilliseconds -ge $DebounceMs) {
                Write-Host "Restart reason: backend source change detected." -ForegroundColor Red
                Restart-FullStack
                continue
            }

            if ($script:restartWeb -and $script:restartDesktop -and ((Get-Date) - $script:lastChange).TotalMilliseconds -ge $DebounceMs) {
                Write-Host "Restarting web and desktop clients..." -ForegroundColor Yellow
                Stop-AppProcess -Process $script:webBrowserProcess
                Stop-AppProcess -Process $script:webProcess
                Stop-AppProcess -Process $script:desktopProcess
                Remove-DirectoryIfExists -Path $script:webUserDataDir
                $script:webProcess = Start-WebApp -BackendPort $script:backendPort
                if (-not (Wait-WebAppReady -Port $script:webPort -Process $script:webProcess)) {
                    Stop-AppProcess -Process $script:webProcess
                    $script:webProcess = $null
                    throw "Web app did not become ready on port $($script:webPort)."
                }
                $script:webBrowserProcess = Start-WebBrowser -Port $script:webPort
                $script:desktopProcess = Start-DesktopApp -BackendPort $script:backendPort
                $script:restartWeb = $false
                $script:restartDesktop = $false
                continue
            }

            if ($script:restartWeb -and ((Get-Date) - $script:lastChange).TotalMilliseconds -ge $DebounceMs) {
                Restart-WebApp
                continue
            }

            if ($script:restartDesktop -and ((Get-Date) - $script:lastChange).TotalMilliseconds -ge $DebounceMs) {
                Restart-DesktopApp
                continue
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

        Stop-AppProcess -Process $script:webBrowserProcess
        Stop-AppProcess -Process $script:webProcess
        Stop-AppProcess -Process $script:desktopProcess
        Stop-AppProcess -Process $script:backendProcess
        Remove-DirectoryIfExists -Path $script:webUserDataDir
    }
}
finally {
    Pop-Location
}

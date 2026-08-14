param(
    [string] $UpdaterPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
if ([string]::IsNullOrWhiteSpace($UpdaterPath)) {
    $UpdaterPath = Join-Path -Path $repoRoot -ChildPath 'update.ps1'
}
$UpdaterPath = [System.IO.Path]::GetFullPath($UpdaterPath)

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $UpdaterPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw "Updater parse failed: $($parseErrors[0].Message)"
}
$functionAst = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Start-DeferredInstall'
    },
    $true
)
if ($null -eq $functionAst) {
    throw 'Start-DeferredInstall was not found in update.ps1.'
}
Invoke-Expression $functionAst.Extent.Text

$retryElevationFunctionAst = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-PriorInstallHandoffNeedsElevation'
    },
    $true
)
if ($null -eq $retryElevationFunctionAst) {
    throw 'Test-PriorInstallHandoffNeedsElevation was not found in update.ps1.'
}
Invoke-Expression $retryElevationFunctionAst.Extent.Text

foreach ($functionName in @(
    'Get-SupervisorScriptPath',
    'Get-PowerShellLaunchText',
    'Stop-LauncherSupervisorProcess'
)) {
    $launcherFunctionAst = $ast.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        },
        $true
    )
    if ($null -eq $launcherFunctionAst) {
        throw "$functionName was not found in update.ps1."
    }
    Invoke-Expression $launcherFunctionAst.Extent.Text
}

$testParent = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'sql sync updater path tests'
$unicodeClient = [string]([char]0x0639) + [char]0x0645 + [char]0x064A + [char]0x0644
$testRoot = Join-Path -Path $testParent -ChildPath ("user O'Brien $unicodeClient " + [guid]::NewGuid().ToString('N'))
$payloadDir = Join-Path -Path $testRoot -ChildPath 'payload files'
$installDir = Join-Path -Path $testRoot -ChildPath 'installed client'
$workRoot = Join-Path -Path $testRoot -ChildPath 'working files'
$resolvedTestParent = [System.IO.Path]::GetFullPath($testParent).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedTestParent, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe updater test path: $resolvedTestRoot"
}

try {
    New-Item -Path (Join-Path $payloadDir 'data') -ItemType Directory -Force | Out-Null
    New-Item -Path $installDir -ItemType Directory -Force | Out-Null
    New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $payloadDir 'sync_windows_agent.exe') -Value 'test-executable' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $payloadDir 'data\app.so') -Value 'test-aot' -Encoding ASCII

    $progressPath = Join-Path $installDir 'update-progress.json'
    @{
        version = '1.0.276+280'
        status = 'installing'
        downloadedBytes = 100
        totalBytes = 100
        percent = 100
        updatedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $progressPath -Encoding UTF8
    if (-not (Test-PriorInstallHandoffNeedsElevation -ProgressPath $progressPath -TargetVersion '1.0.276+280')) {
        throw 'A stale verified install handoff did not request elevation on retry.'
    }
    if (Test-PriorInstallHandoffNeedsElevation -ProgressPath $progressPath -TargetVersion '1.0.275+279') {
        throw 'A progress checkpoint for another version incorrectly requested elevation.'
    }
    $recentProgress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
    $recentProgress.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $recentProgress | ConvertTo-Json -Compress | Set-Content -LiteralPath $progressPath -Encoding UTF8
    if (Test-PriorInstallHandoffNeedsElevation -ProgressPath $progressPath -TargetVersion '1.0.276+280') {
        throw 'A newly scheduled install incorrectly requested elevation before its normal handoff had time to finish.'
    }
    $recentProgress.updatedAt = [DateTimeOffset]::UtcNow.AddSeconds(-6).ToString('o')
    $recentProgress | ConvertTo-Json -Compress | Set-Content -LiteralPath $progressPath -Encoding UTF8
    if (-not (Test-PriorInstallHandoffNeedsElevation -ProgressPath $progressPath -TargetVersion '1.0.276+280')) {
        throw 'A separate verified handoff retry remained non-elevated after the bounded grace period.'
    }

    $supervisorScriptPath = Join-Path $installDir 'sync_windows_agent_supervisor.ps1'
    Set-Content -LiteralPath $supervisorScriptPath -Value 'Start-Sleep -Seconds 60' -Encoding ASCII
    $supervisorProcess = Start-Process powershell.exe `
        -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $supervisorScriptPath.Replace('"', '\"'))
        ) `
        -WindowStyle Hidden `
        -PassThru
    try {
        Start-Sleep -Milliseconds 500
        Stop-LauncherSupervisorProcess -ProcessId $supervisorProcess.Id -TargetInstallDir $installDir
        $supervisorProcess.Refresh()
        if (-not $supervisorProcess.HasExited) {
            throw 'The exact updater-launching supervisor survived the verified handoff stop.'
        }
    }
    finally {
        Stop-Process -Id $supervisorProcess.Id -Force -ErrorAction SilentlyContinue
    }

    $manualCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60')
    )
    $manualProcess = Start-Process powershell.exe `
        -ArgumentList @('-NoProfile', '-EncodedCommand', $manualCommand) `
        -WindowStyle Hidden `
        -PassThru
    try {
        Start-Sleep -Milliseconds 500
        $refusedManualConsole = $false
        try {
            Stop-LauncherSupervisorProcess -ProcessId $manualProcess.Id -TargetInstallDir $installDir
        }
        catch {
            $refusedManualConsole = $true
        }
        $manualProcess.Refresh()
        if (-not $refusedManualConsole -or $manualProcess.HasExited) {
            throw 'Updater launcher validation did not preserve an unrelated manual PowerShell process.'
        }
    }
    finally {
        Stop-Process -Id $manualProcess.Id -Force -ErrorAction SilentlyContinue
    }

    Start-DeferredInstall `
        -PayloadDir $payloadDir `
        -TargetInstallDir $installDir `
        -WorkRoot $workRoot `
        -ParentProcessId ([int]::MaxValue) `
        -Version "1.0.0 path's test" `
        -NoStart

    $updateLog = Join-Path -Path $installDir -ChildPath 'update.log'
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $updateLog -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    while ((Test-Path -LiteralPath $workRoot) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }

    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'sync_windows_agent.exe') -PathType Leaf)) {
        throw 'Deferred updater did not install the executable from a path containing spaces.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'data\app.so') -PathType Leaf)) {
        throw 'Deferred updater did not install the AOT payload from a path containing spaces.'
    }
    $logText = Get-Content -LiteralPath $updateLog -Raw
    if ($logText -notmatch 'Finalize update helper started\.') {
        throw 'Deferred updater helper did not start.'
    }
    if ($logText -notmatch "Verified installed client payload for version 1\.0\.0 path's test\.") {
        throw 'Deferred updater did not preserve an argument containing spaces and an apostrophe.'
    }
    if ($logText -notmatch 'NoStart set\. Skipping client relaunch\.') {
        throw 'Deferred updater did not complete the no-start test path.'
    }

    Write-Host 'PASS deferred updater handles Windows paths, exact supervisor handoff, and stale verified install retries.'
}
finally {
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

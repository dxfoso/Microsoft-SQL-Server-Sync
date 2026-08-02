param(
    [ValidateSet('Quick', 'Standard', 'Matrix', 'Soak', 'All')]
    [string] $Profile = 'Standard',
    [ValidateRange(1, 86400)]
    [int] $SoakSeconds = 60,
    [ValidateRange(1, 10000)]
    [int] $FuzzRounds = 30,
    [ValidateRange(1, 1000000)]
    [int] $ScaleRows = 5000,
    [string] $ResultsDirectory = '',
    [switch] $SkipPrerequisiteTests
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $repoRoot 'workspace\tests\sync-verification'
}
$resultsRoot = [System.IO.Path]::GetFullPath($ResultsDirectory)
New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
$pythonCommand = $null
$pythonPrefix = @()
foreach ($candidate in @('python', 'python3', 'py')) {
    $resolved = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($resolved) {
        $pythonCommand = $resolved.Source
        if ($candidate -eq 'py') {
            $pythonPrefix = @('-3')
        }
        break
    }
}
if (-not $pythonCommand) {
    throw 'Python 3 is required (python, python3, or the Windows py launcher).'
}

$started = [DateTimeOffset]::UtcNow
$runId = if ($env:ACTION_SERVER_RUN_ID) {
    $env:ACTION_SERVER_RUN_ID
} elseif ($env:GITHUB_RUN_ID) {
    $env:GITHUB_RUN_ID
} else {
    $started.ToUnixTimeSeconds().ToString()
}
$trigger = if ($env:ACTION_SERVER_TRIGGER) {
    $env:ACTION_SERVER_TRIGGER
} elseif ($env:GITHUB_EVENT_NAME) {
    $env:GITHUB_EVENT_NAME
} else {
    'manual'
}
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
$gitRef = (& git -C $repoRoot branch --show-current).Trim()
$steps = [System.Collections.Generic.List[object]]::new()
$failed = $false

function ConvertTo-StepId {
    param([Parameter(Mandatory = $true)][string] $Name)
    $value = $Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    return $value.Trim('-')
}

function Invoke-VerificationStep {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )
    $stepStarted = [DateTimeOffset]::UtcNow
    $stepId = ConvertTo-StepId $Name
    $logPath = Join-Path $resultsRoot "$stepId.log"
    $status = 'passed'
    $detail = 'ok'
    try {
        & $Action *>&1 | Tee-Object -FilePath $logPath
    }
    catch {
        $status = 'failed'
        $detail = $_.Exception.Message
        $_ | Out-String | Add-Content -LiteralPath $logPath -Encoding utf8
        $script:failed = $true
    }
    $stepFinished = [DateTimeOffset]::UtcNow
    $steps.Add([ordered]@{
        id = $stepId
        name = $Name
        status = $status
        durationSeconds = [Math]::Max(
            0,
            [int][Math]::Round(($stepFinished - $stepStarted).TotalSeconds)
        )
        log = $logPath
        detail = $detail
    })
    if ($status -eq 'failed') {
        throw "Verification step failed: $Name. See $logPath"
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string] $Executable,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [string] $WorkingDirectory = $repoRoot
    )
    Push-Location $WorkingDirectory
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell can promote ordinary native stderr (for example,
        # unittest progress) to a terminating NativeCommandError even on exit 0.
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $nativeExitCode = $LASTEXITCODE
        if ($nativeExitCode -ne 0) {
            throw "$Executable failed with exit code $nativeExitCode."
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Invoke-DockerSyncSuite {
    param(
        [Parameter(Mandatory = $true)][string] $Suite,
        [int] $RequestedSoakSeconds = $SoakSeconds,
        [switch] $SkipSqlRestart
    )
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $repoRoot 'tests\docker-sync\run.ps1'),
        '-Suite', $Suite,
        '-SoakSeconds', $RequestedSoakSeconds,
        '-FuzzRounds', $FuzzRounds,
        '-ScaleRows', $ScaleRows,
        '-SkipPrerequisiteTests'
    )
    if ($SkipSqlRestart) {
        $arguments += '-SkipSqlRestart'
    }
    Invoke-NativeChecked -Executable 'powershell.exe' -Arguments $arguments
}

Push-Location $repoRoot
try {
    if (-not $SkipPrerequisiteTests) {
        Invoke-VerificationStep 'Flutter analysis and tests' {
            Invoke-NativeChecked -Executable 'flutter' -Arguments @('analyze') -WorkingDirectory (Join-Path $repoRoot 'sync_windows_agent')
            Invoke-NativeChecked -Executable 'flutter' -Arguments @('test') -WorkingDirectory (Join-Path $repoRoot 'sync_windows_agent')
        }
        Invoke-VerificationStep 'Repository contract tests' {
            foreach ($testFile in @(
                'tests/test_sync_contracts.py',
                'tests/test_control_plane_contracts.py',
                'tests/test_control_plane_perf_contracts.py',
                'tests/test_docker_sync_harness.py',
                'tests/test_heartbeat_contracts.py',
                'tests/test_live_verifier_scripts.py'
            )) {
                Invoke-NativeChecked -Executable $pythonCommand -Arguments @($pythonPrefix + $testFile)
            }
        }
        Invoke-VerificationStep 'Windows updater paths with spaces' {
            Invoke-NativeChecked -Executable 'powershell.exe' -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $repoRoot 'tests\test_windows_updater_paths.ps1')
            )
        }
    }

    if ($Profile -in @('Quick', 'Standard', 'All')) {
        Invoke-VerificationStep 'SQL Server 2022 standard sync' {
            $env:SQL_SYNC_TEST_IMAGE = 'mcr.microsoft.com/mssql/server:2022-latest'
            Invoke-DockerSyncSuite -Suite 'standard'
        }
    }
    if ($Profile -in @('Standard', 'All')) {
        Invoke-VerificationStep 'SQL Server 2022 atomic chaos concurrency fuzz and scale' {
            $env:SQL_SYNC_TEST_IMAGE = 'mcr.microsoft.com/mssql/server:2022-latest'
            Invoke-DockerSyncSuite -Suite 'robustness'
        }
        Invoke-VerificationStep 'SQL Server 2022 bounded soak' {
            $env:SQL_SYNC_TEST_IMAGE = 'mcr.microsoft.com/mssql/server:2022-latest'
            Invoke-DockerSyncSuite -Suite 'soak' -RequestedSoakSeconds $SoakSeconds -SkipSqlRestart
        }
    }
    if ($Profile -in @('Matrix', 'All')) {
        foreach ($entry in @(
            @{ Name = 'SQL Server 2017 compatibility'; Image = 'mcr.microsoft.com/mssql/server:2017-latest' },
            @{ Name = 'SQL Server 2019 compatibility'; Image = 'mcr.microsoft.com/mssql/server:2019-latest' },
            @{ Name = 'SQL Server 2022 compatibility'; Image = 'mcr.microsoft.com/mssql/server:2022-latest' }
        )) {
            Invoke-VerificationStep $entry.Name {
                $env:SQL_SYNC_TEST_IMAGE = $entry.Image
                Invoke-DockerSyncSuite -Suite 'standard' -SkipSqlRestart
            }
        }
    }
    if ($Profile -eq 'Soak') {
        Invoke-VerificationStep 'SQL Server randomized soak' {
            $env:SQL_SYNC_TEST_IMAGE = 'mcr.microsoft.com/mssql/server:2022-latest'
            Invoke-DockerSyncSuite -Suite 'soak' -RequestedSoakSeconds $SoakSeconds -SkipSqlRestart
        }
    }
}
catch {
    $failed = $true
    $failureMessage = $_.Exception.Message
}
finally {
    Remove-Item Env:SQL_SYNC_TEST_IMAGE -ErrorAction SilentlyContinue
    Pop-Location
}

$finished = [DateTimeOffset]::UtcNow
$duration = [Math]::Max(0, [int][Math]::Round(($finished - $started).TotalSeconds))
$status = if ($failed) { 'failed' } else { 'passed' }
$metadata = [ordered]@{
    task = 'sync-verification'
    status = $status
    trigger = $trigger
    profile = $Profile
    startedAt = $started.ToString('o')
    finishedAt = $finished.ToString('o')
    durationSeconds = $duration
    runId = $runId
    commit = $commit
    ref = $gitRef
}
$statusPayload = [ordered]@{}
foreach ($item in $metadata.GetEnumerator()) {
    $statusPayload[$item.Key] = $item.Value
}
$statusPayload.detail = if ($failed) { $failureMessage } else { 'All requested sync verification steps passed.' }
$resultPayload = [ordered]@{}
foreach ($item in $metadata.GetEnumerator()) {
    $resultPayload[$item.Key] = $item.Value
}
$resultPayload.summary = if ($failed) { 'Sync verification failed.' } else { 'Sync verification completed successfully.' }
$resultPayload.steps = @($steps)
$stepPayload = [ordered]@{
    task = 'sync-verification'
    generatedAt = $finished.ToString('o')
    durationSeconds = $duration
    trigger = $trigger
    profile = $Profile
    results = @($steps)
}

$statusPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resultsRoot 'task-status.json') -Encoding utf8
$resultPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resultsRoot 'task-results.json') -Encoding utf8
$stepPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resultsRoot 'task-step-results.json') -Encoding utf8
@(
    "Task: sync-verification"
    "Status: $status"
    "Trigger: $trigger"
    "Profile: $Profile"
    "Commit: $commit"
    "Ref: $gitRef"
    "Started: $($started.ToString('o'))"
    "Finished: $($finished.ToString('o'))"
    "DurationSeconds: $duration"
    "Steps: $(@($steps | Where-Object status -eq 'passed').Count) passed, $(@($steps | Where-Object status -eq 'failed').Count) failed"
    ''
    ($steps | ForEach-Object { "- $($_.name): $($_.status) [$($_.durationSeconds)s] $($_.log)" })
) | Set-Content -LiteralPath (Join-Path $resultsRoot 'final-summary.txt') -Encoding utf8

if ($failed) {
    throw $failureMessage
}

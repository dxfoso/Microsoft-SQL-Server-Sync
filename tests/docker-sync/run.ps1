param(
    [switch] $Keep,
    [ValidateSet('standard', 'robustness', 'soak', 'all')]
    [string] $Suite = 'standard',
    [ValidateRange(1, 86400)]
    [int] $SoakSeconds = 60,
    [ValidateRange(1, 10000)]
    [int] $FuzzRounds = 30,
    [ValidateRange(1, 1000000)]
    [int] $ScaleRows = 5000,
    [switch] $SkipPrerequisiteTests,
    [switch] $SkipSqlRestart,
    [switch] $External
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$pythonCommand = $null
$pythonPrefix = @()
$pythonCandidates = @(
    [pscustomobject]@{ Command = 'python'; Prefix = @() },
    [pscustomobject]@{ Command = 'python3'; Prefix = @() },
    [pscustomobject]@{ Command = 'py'; Prefix = @('-3') }
)
if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $pythonCandidates += @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\python.exe') -File -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object { [pscustomobject]@{ Command = $_.FullName; Prefix = @() } })
}
foreach ($programsRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not [string]::IsNullOrWhiteSpace($programsRoot)) {
        $pythonCandidates += @(Get-ChildItem -Path (Join-Path $programsRoot 'Python*\python.exe') -File -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object { [pscustomobject]@{ Command = $_.FullName; Prefix = @() } })
    }
}
foreach ($candidate in $pythonCandidates) {
    $resolved = Get-Command ([string]$candidate.Command) -ErrorAction SilentlyContinue
    if (-not $resolved) { continue }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & $resolved.Source @($candidate.Prefix) --version *> $null
    $candidateExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($candidateExitCode -eq 0) {
        $pythonCommand = $resolved.Source
        $pythonPrefix = @($candidate.Prefix)
        break
    }
}
if (-not $pythonCommand) {
    throw 'Python 3 is required (python, python3, or the Windows py launcher).'
}

function Invoke-PythonChecked {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    & $pythonCommand @pythonPrefix @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed with exit code $LASTEXITCODE."
    }
}

Push-Location $repoRoot
try {
    if (-not $SkipPrerequisiteTests) {
        Push-Location "$repoRoot\sync_windows_agent"
        try {
            flutter test test/sql_sync_merge_test.dart test/sql_bulk_stage_test.dart test/sql_cmd_output_test.dart
            if ($LASTEXITCODE -ne 0) {
                throw 'Flutter sync contract tests failed.'
            }
        }
        finally {
            Pop-Location
        }
        foreach ($contractTest in @(
            "$repoRoot\tests\test_sync_contracts.py",
            "$repoRoot\tests\test_control_plane_contracts.py",
            "$repoRoot\tests\test_heartbeat_contracts.py"
        )) {
            Invoke-PythonChecked -Arguments @($contractTest)
        }
    }
    $arguments = @(
        "$PSScriptRoot\run_scenarios.py",
        '--suite', $Suite,
        '--soak-seconds', $SoakSeconds,
        '--fuzz-rounds', $FuzzRounds,
        '--scale-rows', $ScaleRows
    )
    if ($Keep) {
        $arguments += '--keep'
    }
    if ($SkipSqlRestart) {
        $arguments += '--skip-sql-restart'
    }
    if ($External) {
        $arguments += '--external'
    }
    Invoke-PythonChecked -Arguments $arguments
}
finally {
    Pop-Location
}

<#
.SYNOPSIS
    Runs the complete local sync test standard in a hidden child process.

.DESCRIPTION
    This is the supported developer entry point for local verification. It
    delegates to run_sync_verification.ps1, writes all output and machine-
    readable result files under workspace/tests, and never opens a visible
    console for the long-running Flutter or Docker work.
#>
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
    [switch] $Child
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $ResultsDirectory = Join-Path $repoRoot 'workspace\tests\local-standard'
}
$resultsRoot = [System.IO.Path]::GetFullPath($ResultsDirectory)
New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

$verificationScript = Join-Path $repoRoot 'tests\run_sync_verification.ps1'
if (-not (Test-Path -LiteralPath $verificationScript -PathType Leaf)) {
    throw "Missing verification runner: $verificationScript"
}

if ($Child) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verificationScript `
            -Profile $Profile `
            -SoakSeconds $SoakSeconds `
            -FuzzRounds $FuzzRounds `
            -ScaleRows $ScaleRows `
            -ResultsDirectory $resultsRoot
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
        exit 0
    }
    catch {
        $_ | Out-String | Add-Content -LiteralPath (Join-Path $resultsRoot 'launcher-error.log') -Encoding utf8
        exit 1
    }
}

$stdoutPath = Join-Path $resultsRoot 'launcher.log'
$stderrPath = Join-Path $resultsRoot 'launcher-error.log'
$childArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $PSCommandPath,
    '-Profile', $Profile,
    '-SoakSeconds', $SoakSeconds,
    '-FuzzRounds', $FuzzRounds,
    '-ScaleRows', $ScaleRows,
    '-ResultsDirectory', $resultsRoot,
    '-Child'
)
$childProcess = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList $childArguments `
    -WorkingDirectory $repoRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru
Set-Content -LiteralPath (Join-Path $resultsRoot 'launcher.pid') -Value $childProcess.Id -Encoding ascii

try {
    Wait-Process -Id $childProcess.Id
    $exitCode = $childProcess.ExitCode
}
finally {
    Remove-Item -LiteralPath (Join-Path $resultsRoot 'launcher.pid') -Force -ErrorAction SilentlyContinue
}

$statusPath = Join-Path $resultsRoot 'task-status.json'
if (Test-Path -LiteralPath $statusPath) {
    Get-Content -LiteralPath $statusPath -Raw | Write-Output
}
if ($exitCode -ne 0) {
    throw "Local test standard failed with exit code $exitCode. See $resultsRoot"
}
Write-Output "Local test standard passed. Results: $resultsRoot"

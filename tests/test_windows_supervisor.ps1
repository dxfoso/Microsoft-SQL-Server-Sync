param(
    [string] $SupervisorPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($SupervisorPath)) {
    $SupervisorPath = Join-Path $repoRoot 'sync_windows_agent_supervisor.ps1'
}
$SupervisorPath = [System.IO.Path]::GetFullPath($SupervisorPath)
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('sql-sync-supervisor-test-' + [guid]::NewGuid().ToString('N'))
$testRoot = [System.IO.Path]::GetFullPath($testRoot)
if (-not $testRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe supervisor test path: $testRoot"
}

$supervisorProcess = $null
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
try {
    $testSupervisor = Join-Path $testRoot 'sync_windows_agent_supervisor.ps1'
    Copy-Item -LiteralPath $SupervisorPath -Destination $testSupervisor -Force
    @'
param([string] $ManifestUrl, [string] $InstallDir, [switch] $NoStart)
exit 0
'@ | Set-Content -LiteralPath (Join-Path $testRoot 'update.ps1') -Encoding ASCII

    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $testSupervisor `
        -RunOnce `
        -SkipAgentStart `
        -SkipObsoleteRetirement
    if ($LASTEXITCODE -ne 0) {
        throw "Supervisor RunOnce failed with exit code $LASTEXITCODE."
    }

    $requestLog = Get-Content -LiteralPath (Join-Path $testRoot 'sync_windows_agent_update_requests.log') -Raw
    if ($requestLog -notmatch 'Update request started' -or $requestLog -notmatch 'exitCode=0') {
        throw 'The independent request log did not record the update lifecycle.'
    }

    $supervisorProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-WindowStyle', 'Hidden',
            '-File', $testSupervisor,
            '-SkipUpdate',
            '-SkipObsoleteRetirement'
        ) `
        -WorkingDirectory $testRoot `
        -WindowStyle Hidden `
        -PassThru
    Start-Sleep -Seconds 2
    if ($supervisorProcess.HasExited) {
        throw "Supervisor exited while the client executable was absent. exit=$($supervisorProcess.ExitCode)"
    }

    $supervisorLog = Get-Content -LiteralPath (Join-Path $testRoot 'sync_windows_agent_supervisor.log') -Raw
    if ($supervisorLog -notmatch 'Agent executable is unavailable; supervisor remains active') {
        throw 'The supervisor did not log missing-client survival.'
    }

    Write-Host "PASS independent request logging and missing-client survival pid=$($supervisorProcess.Id)"
}
finally {
    if ($null -ne $supervisorProcess -and -not $supervisorProcess.HasExited) {
        Stop-Process -Id $supervisorProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 300
    if ($testRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

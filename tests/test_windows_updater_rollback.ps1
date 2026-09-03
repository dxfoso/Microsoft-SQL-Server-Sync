param([string] $UpdaterPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($UpdaterPath)) {
    $UpdaterPath = Join-Path $repoRoot 'update.ps1'
}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    ([System.IO.Path]::GetFullPath($UpdaterPath)),
    [ref] $tokens,
    [ref] $parseErrors
)
if (@($parseErrors).Count -gt 0) { throw "Updater parse failed: $($parseErrors[0].Message)" }
$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Start-DeferredInstall'
}, $true)
if ($null -eq $functionAst) { throw 'Start-DeferredInstall was not found.' }
Invoke-Expression $functionAst.Extent.Text

function Read-UpdateLogWithRetry {
    param([Parameter(Mandatory = $true)][string] $Path)

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        try {
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $reader = [System.IO.StreamReader]::new($stream)
                try { return $reader.ReadToEnd() }
                finally { $reader.Dispose() }
            }
            finally { $stream.Dispose() }
        }
        catch [System.IO.IOException] {
            if ($attempt -eq 10) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sql-sync-updater-rollback-" + [guid]::NewGuid().ToString('N'))
$installDir = Join-Path $testRoot 'install'
$payloadDir = Join-Path $testRoot 'payload'
$workRoot = Join-Path $testRoot 'work'
$oldSource = Join-Path $testRoot 'stable-client.cs'
$failingSource = Join-Path $testRoot 'failing-client.cs'
$oldExe = Join-Path $installDir 'sync_windows_agent.exe'
$env:SYNC_WINDOWS_AGENT_SUPERVISOR_SKIP_UPDATE = '1'
$env:SYNC_WINDOWS_AGENT_SUPERVISOR_SKIP_OBSOLETE_RETIREMENT = '1'
$env:SYNC_WINDOWS_AGENT_UPDATE_STABLE_SECONDS = '2'
$env:SYNC_WINDOWS_AGENT_UPDATE_STARTUP_TIMEOUT_SECONDS = '3'

try {
    New-Item -Path $installDir, $payloadDir, $workRoot -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $oldSource -Encoding ASCII -Value @'
using System;
using System.Threading;
public static class Program {
    public static int Main(string[] args) { Thread.Sleep(120000); return 0; }
}
'@
    Add-Type -TypeDefinition (Get-Content -LiteralPath $oldSource -Raw) -Language CSharp -OutputAssembly $oldExe -OutputType ConsoleApplication
    Copy-Item -LiteralPath (Join-Path $repoRoot 'sync_windows_agent_supervisor.ps1') -Destination (Join-Path $installDir 'sync_windows_agent_supervisor.ps1')
    Set-Content -LiteralPath (Join-Path $installDir 'update.ps1') -Value 'exit 0' -Encoding ASCII
    $oldHash = (Get-FileHash -LiteralPath $oldExe -Algorithm SHA256).Hash

    Set-Content -LiteralPath $failingSource -Encoding ASCII -Value @'
public static class FailingProgram {
    public static int Main(string[] args) { return 7; }
}
'@
    Add-Type -TypeDefinition (Get-Content -LiteralPath $failingSource -Raw) -Language CSharp -OutputAssembly (Join-Path $payloadDir 'sync_windows_agent.exe') -OutputType ConsoleApplication
    Copy-Item -LiteralPath (Join-Path $repoRoot 'sync_windows_agent_supervisor.ps1') -Destination (Join-Path $payloadDir 'sync_windows_agent_supervisor.ps1')

    Start-DeferredInstall -PayloadDir $payloadDir -TargetInstallDir $installDir -WorkRoot $workRoot -ParentProcessId ([int]::MaxValue) -Version 'rollback-test'
    $logPath = Join-Path $installDir 'update.log'
    # A cold Windows host can consume the full 45-second supervisor-launch
    # bound both before rollback and while restarting the restored client, in
    # addition to both startup-stability windows. Keep the test observer beyond
    # the complete two-launch product bound without weakening any assertion.
    $deadline = [DateTime]::UtcNow.AddSeconds(150)
    do {
        Start-Sleep -Milliseconds 200
        $logText = Read-UpdateLogWithRetry -Path $logPath
    } while ($logText -notmatch 'Rollback files restored and verified' -and [DateTime]::UtcNow -lt $deadline)

    if ($logText -notmatch 'rolling back the complete managed-file change set') {
        throw "Failed startup did not trigger rollback. Final update log: $logText"
    }
    if ($logText -notmatch 'Rollback files restored and verified') {
        throw "Rollback restoration was not logged. Final update log: $logText"
    }
    if ((Get-FileHash -LiteralPath $oldExe -Algorithm SHA256).Hash -ne $oldHash) { throw 'Rollback did not restore the original executable.' }
    if ($logText -notmatch 'restarting the previous client') { throw 'Rollback did not request restart of the previous executable.' }
    Write-Host 'PASS failed replacement startup atomically restores the previous Windows client and requests its supervised restart.'
}
finally {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and $_.ExecutablePath.StartsWith($testRoot, [System.StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
        -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and $_.CommandLine.IndexOf($testRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:SYNC_WINDOWS_AGENT_SUPERVISOR_SKIP_UPDATE -ErrorAction SilentlyContinue
    Remove-Item Env:SYNC_WINDOWS_AGENT_SUPERVISOR_SKIP_OBSOLETE_RETIREMENT -ErrorAction SilentlyContinue
    Remove-Item Env:SYNC_WINDOWS_AGENT_UPDATE_STABLE_SECONDS -ErrorAction SilentlyContinue
    Remove-Item Env:SYNC_WINDOWS_AGENT_UPDATE_STARTUP_TIMEOUT_SECONDS -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

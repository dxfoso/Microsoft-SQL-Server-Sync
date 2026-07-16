param(
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

Push-Location $repoRoot
try {
    Push-Location "$repoRoot\sync_windows_agent"
    try {
        flutter test test/sql_sync_merge_test.dart test/sql_sync_row_isolation_test.dart
    }
    finally {
        Pop-Location
    }
    python -m unittest tests.test_sync_contracts tests.test_control_plane_contracts tests.test_heartbeat_contracts
    $arguments = @("$PSScriptRoot\run_scenarios.py")
    if ($Keep) {
        $arguments += '--keep'
    }
    python @arguments
}
finally {
    Pop-Location
}

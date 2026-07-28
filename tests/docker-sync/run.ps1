param(
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

Push-Location $repoRoot
try {
    Push-Location "$repoRoot\sync_windows_agent"
    try {
        flutter test test/sql_sync_merge_test.dart test/sql_cmd_output_test.dart
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
        python $contractTest
        if ($LASTEXITCODE -ne 0) {
            throw "Sync contract test failed: $contractTest"
        }
    }
    $arguments = @("$PSScriptRoot\run_scenarios.py")
    if ($Keep) {
        $arguments += '--keep'
    }
    python @arguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker sync scenarios failed.'
    }
}
finally {
    Pop-Location
}

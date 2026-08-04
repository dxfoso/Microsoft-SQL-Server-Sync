$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sql-sync-multi-instance-" + [guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'source'
$instances = Join-Path $testRoot 'instances'
$appData = Join-Path $testRoot 'appdata'

try {
    New-Item -Path $source -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $appData 'Microsoft-SQL-Server-Sync') -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $source 'sync_windows_agent.exe') -Value 'fake' -Encoding ASCII
    Copy-Item -LiteralPath (Join-Path $repoRoot 'sync_windows_agent_supervisor.ps1') -Destination $source
    Copy-Item -LiteralPath (Join-Path $repoRoot 'create_client_instance.ps1') -Destination $source
    $state = [ordered]@{
        server = 'old-server'
        accountUsername = 'alshallan2'
        accountEmail = 'alshallan2@example.test'
        accountName = 'Alshallan2'
        rememberedLoginName = 'alshallan2'
        selectedDatabasesByUser = [ordered]@{ alshallan2 = 'OldDb' }
        clients = [ordered]@{}
    }
    $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $appData 'Microsoft-SQL-Server-Sync\sync_windows_agent_state.json') -Encoding UTF8

    $previousAppData = $env:APPDATA
    $env:APPDATA = $appData
    try {
        $result = & (Join-Path $repoRoot 'create_client_instance.ps1') `
            -InstanceId 'sql8' `
            -DisplayName 'Alshallan2 SQL8' `
            -Server 'DESKTOP-6MQFNA3\SQL8' `
            -Database 'AmnDb048' `
            -SourceInstallDir $source `
            -InstancesRoot $instances `
            -NoStart
    }
    finally {
        $env:APPDATA = $previousAppData
    }

    $target = Join-Path $instances 'sql8'
    if (-not (Test-Path -LiteralPath (Join-Path $target 'sync_windows_agent.exe') -PathType Leaf)) {
        throw 'Secondary executable was not copied.'
    }
    $config = Get-Content -LiteralPath (Join-Path $target 'client-instance.json') -Raw | ConvertFrom-Json
    if ($config.id -ne 'sql8' -or $config.displayName -ne 'Alshallan2 SQL8') {
        throw 'Secondary instance marker is incorrect.'
    }
    $copiedState = Get-Content -LiteralPath (Join-Path $appData 'Microsoft-SQL-Server-Sync\instances\sql8\sync_windows_agent_state.json') -Raw | ConvertFrom-Json
    if ($copiedState.server -ne 'DESKTOP-6MQFNA3\SQL8') {
        throw 'Secondary SQL Server selection is incorrect.'
    }
    if ($copiedState.selectedDatabasesByUser.alshallan2 -ne 'AmnDb048') {
        throw 'Secondary database selection is incorrect.'
    }
    if ($result.Started -ne $false) {
        throw 'NoStart unexpectedly launched an instance.'
    }
    Write-Host 'Windows multi-instance client test passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($resolvedTestRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTestRoot).StartsWith('sql-sync-multi-instance-')) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SummaryPath,
    [string] $SqlImage = 'mcr.microsoft.com/mssql/server:2022-latest',
    [string] $SaPassword = 'SqlSync_LiveCopy_2026!',
    [string] $OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$summaryFile = Get-Item -LiteralPath $SummaryPath
$copyRoot = $summaryFile.Directory.FullName
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $copyRoot 'docker-restores.json'
}
$entries = @(Get-Content -Raw -LiteralPath $summaryFile.FullName | ConvertFrom-Json)
if ($entries.Count -eq 0) { throw 'The live-copy summary contains no backups.' }

function Invoke-Sqlcmd {
    param([string] $Container, [string] $Query, [switch] $Raw)
    $tools = '/opt/mssql-tools18/bin/sqlcmd'
    & docker exec $Container sh -c "if [ -x $tools ]; then $tools -C -S localhost -U sa -P '$SaPassword' -b -W -h -1 -s '|' -Q `"$Query`"; else /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P '$SaPassword' -b -W -h -1 -s '|' -Q `"$Query`"; fi"
    if ($LASTEXITCODE -ne 0) { throw "SQL command failed in $Container" }
}

$results = @()
$runId = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
foreach ($entry in $entries) {
    $backup = Get-Item -LiteralPath ([string]$entry.backup)
    if (-not $backup.Directory.FullName.Equals($copyRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Backup must stay beside summary.json: $($backup.FullName)"
    }
    $expectedHash = ([string]$entry.sha256).ToLowerInvariant()
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup.FullName).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "Backup checksum failed: $($backup.Name)" }

    $safeKey = ([string]$entry.clientKey -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    if ($safeKey.Length -gt 18) { $safeKey = $safeKey.Substring(0, 18) }
    $container = "sql-sync-copy-$runId-$safeKey"
    $database = "LiveCopy_${safeKey}_$([string]$entry.database -replace '[^A-Za-z0-9_]', '_')"
    & docker run -d --name $container -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e "MSSQL_SA_PASSWORD=$SaPassword" -v "${copyRoot}:/backups:ro" $SqlImage | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to start $container" }

    $ready = $false
    for ($attempt = 0; $attempt -lt 90; $attempt += 1) {
        try {
            Invoke-Sqlcmd -Container $container -Query 'SET NOCOUNT ON; SELECT 1;' | Out-Null
            $ready = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $ready) { throw "SQL Server did not become ready in $container" }

    $backupPath = "/backups/$($backup.Name)"
    $fileRows = @(Invoke-Sqlcmd -Container $container -Query "RESTORE FILELISTONLY FROM DISK = N'$backupPath';")
    $logicalFiles = @()
    foreach ($line in $fileRows) {
        $parts = ([string]$line).Split('|')
        if ($parts.Count -ge 3 -and @('D', 'L', 'F', 'S') -contains $parts[2].Trim()) {
            $logicalFiles += [pscustomobject]@{ logical = $parts[0].Trim(); type = $parts[2].Trim() }
        }
    }
    if ($logicalFiles.Count -lt 2) { throw "Could not parse backup logical files for $($entry.clientName)." }
    $moves = @()
    for ($index = 0; $index -lt $logicalFiles.Count; $index += 1) {
        $logical = $logicalFiles[$index].logical.Replace("'", "''")
        $extension = if ($logicalFiles[$index].type -eq 'L') { 'ldf' } else { 'mdf' }
        $moves += "MOVE N'$logical' TO N'/var/opt/mssql/data/$database-$index.$extension'"
    }
    $restore = "RESTORE DATABASE [$database] FROM DISK = N'$backupPath' WITH REPLACE, RECOVERY, CHECKSUM, $($moves -join ', ');"
    Invoke-Sqlcmd -Container $container -Query $restore | Out-Null
    Invoke-Sqlcmd -Container $container -Query "DBCC CHECKDB (N'$database') WITH NO_INFOMSGS, ALL_ERRORMSGS;" | Out-Null
    $inventory = @(Invoke-Sqlcmd -Container $container -Query "SET NOCOUNT ON; SELECT COUNT_BIG(1), COALESCE(SUM(p.rows),0) FROM [$database].sys.tables t LEFT JOIN [$database].sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1) WHERE t.is_ms_shipped=0;")
    $values = ([string]$inventory[0]).Split('|')
    $results += [pscustomobject]@{
        clientName = [string]$entry.clientName
        clientKey = [string]$entry.clientKey
        sourceDatabase = [string]$entry.database
        container = $container
        restoredDatabase = $database
        tableCount = [long]$values[0].Trim()
        allocatedRowCount = [long]$values[1].Trim()
        backupSha256 = $actualHash
        checkDb = 'passed'
    }
}

$results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$results | Format-Table -AutoSize
Write-Host "Isolated Docker restores verified: $OutputPath"

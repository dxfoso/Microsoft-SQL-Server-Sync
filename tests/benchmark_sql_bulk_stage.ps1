param(
    [string] $Server = 'localhost,14333',
    [string] $User = 'sa',
    [string] $Password = 'SqlSync_Test_2026!',
    [ValidateRange(1000, 100000)]
    [int] $Rows = 14030,
    [ValidateRange(1.0, 100.0)]
    [double] $MinimumSpeedup = 1.25
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
$workspace = Join-Path $repoRoot 'workspace\tests\sql-bulk-stage'
New-Item -ItemType Directory -Path $workspace -Force | Out-Null

function Invoke-SqlFile {
    param([Parameter(Mandatory = $true)][string] $Sql)
    $path = Join-Path $workspace 'command.sql'
    [System.IO.File]::WriteAllText($path, $Sql, [System.Text.UTF8Encoding]::new($false))
    $output = @(& $sqlcmd -S $Server -U $User -P $Password -N disable -C -b -i $path 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Out-String).Trim()
        throw "sqlcmd failed with exit code $LASTEXITCODE.`n$details"
    }
}

function Get-StageCount {
    $output = & $sqlcmd -S $Server -U $User -P $Password -N disable -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM tempdb.dbo.sqlsync_bulk_benchmark;"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read benchmark stage count.' }
    return [long](@($output | Where-Object { $_ -match '^\s*\d+\s*$' })[0].Trim())
}

function Get-SqlScalar {
    param([Parameter(Mandatory = $true)][string] $Query)
    $output = & $sqlcmd -S $Server -U $User -P $Password -N disable -C -b -h -1 -W -Q "SET NOCOUNT ON; $Query"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read benchmark verification value.' }
    return [string](@($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[0].Trim())
}

$columns = @(
    [ordered]@{ name = 'Id'; sqlType = 'int' },
    [ordered]@{ name = 'ExternalId'; sqlType = 'uniqueidentifier' },
    [ordered]@{ name = 'ArabicName'; sqlType = 'nvarchar' },
    [ordered]@{ name = 'Notes'; sqlType = 'nvarchar' },
    [ordered]@{ name = 'Amount'; sqlType = 'decimal' },
    [ordered]@{ name = 'ChangedAt'; sqlType = 'datetime2' },
    [ordered]@{ name = 'Payload'; sqlType = 'varbinary' },
    [ordered]@{ name = 'Enabled'; sqlType = 'bit' }
)
$arabicPrefix = -join @(
    [char]0x0639,
    [char]0x0645,
    [char]0x064A,
    [char]0x0644
)
$dataRows = [System.Collections.Generic.List[object]]::new($Rows)
for ($index = 1; $index -le $Rows; $index += 1) {
    $dataRows.Add(@(
        $index.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        ([guid]::NewGuid().ToString()),
        "$arabicPrefix $index",
        ("invoice-$index-" + ('x' * 120)),
        (($index * 1.25).ToString([System.Globalization.CultureInfo]::InvariantCulture)),
        '2026-08-12T12:34:56.1234567',
        ('0x' + $index.ToString('X8')),
        ($(if (($index % 2) -eq 0) { '1' } else { '0' }))
    ))
}

Invoke-SqlFile @'
IF OBJECT_ID(N'tempdb.dbo.sqlsync_bulk_benchmark', N'U') IS NOT NULL
  DROP TABLE tempdb.dbo.sqlsync_bulk_benchmark;
CREATE TABLE tempdb.dbo.sqlsync_bulk_benchmark (
  __row_num int IDENTITY(1,1) NOT NULL,
  Id int NULL,
  ExternalId uniqueidentifier NULL,
  ArabicName nvarchar(100) NULL,
  Notes nvarchar(300) NULL,
  Amount decimal(18,2) NULL,
  ChangedAt datetime2(7) NULL,
  Payload varbinary(16) NULL,
  Enabled bit NULL
);
'@

$requestPath = Join-Path $workspace 'bulk-request.json'
$bulkWatch = [System.Diagnostics.Stopwatch]::StartNew()
for ($offset = 0; $offset -lt $Rows; $offset += 10000) {
    $chunkCount = [Math]::Min(10000, $Rows - $offset)
    $request = [ordered]@{
        server = $Server
        database = 'tempdb'
        useWindowsAuth = $false
        user = $User
        password = $Password
        destinationTable = '[tempdb].[dbo].[sqlsync_bulk_benchmark]'
        connectTimeoutSeconds = 30
        commandTimeoutSeconds = 600
        commitBatchRows = 1000
        columns = $columns
        rows = $dataRows.GetRange($offset, $chunkCount)
    }
    [System.IO.File]::WriteAllText(
        $requestPath,
        ($request | ConvertTo-Json -Depth 6 -Compress),
        [System.Text.UTF8Encoding]::new($false)
    )
    & powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'sync_windows_agent\assets\sql_bulk_stage.ps1') -RequestPath $requestPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SqlBulkCopy benchmark failed with exit code $LASTEXITCODE." }
}
$bulkWatch.Stop()
if ((Get-StageCount) -ne $Rows) { throw 'SqlBulkCopy benchmark did not preserve every row.' }
$expectedArabicHex = [BitConverter]::ToString(
    [Text.Encoding]::Unicode.GetBytes("$arabicPrefix 1")
).Replace('-', '')
$actualArabicHex = Get-SqlScalar "SELECT CONVERT(varchar(max), CONVERT(varbinary(max), ArabicName), 2) FROM tempdb.dbo.sqlsync_bulk_benchmark WHERE Id = 1;"
if ($actualArabicHex -ne $expectedArabicHex) { throw 'SqlBulkCopy changed Arabic Unicode text.' }
$actualTypedValues = Get-SqlScalar "SELECT CONCAT(CONVERT(varchar(30), Amount), '|', CONVERT(varchar(40), ChangedAt, 126), '|', CONVERT(varchar(max), Payload, 2), '|', CONVERT(varchar(1), Enabled)) FROM tempdb.dbo.sqlsync_bulk_benchmark WHERE Id = 1;"
if ($actualTypedValues -ne '1.25|2026-08-12T12:34:56.1234567|00000001|0') {
    throw "SqlBulkCopy changed typed values: $actualTypedValues"
}

Invoke-SqlFile 'TRUNCATE TABLE tempdb.dbo.sqlsync_bulk_benchmark;'
$literalWatch = [System.Diagnostics.Stopwatch]::StartNew()
for ($offset = 0; $offset -lt $Rows; $offset += 1000) {
    $end = [Math]::Min($Rows, $offset + 1000)
    $tuples = [System.Text.StringBuilder]::new()
    for ($rowIndex = $offset; $rowIndex -lt $end; $rowIndex += 1) {
        $row = $dataRows[$rowIndex]
        if ($tuples.Length -gt 0) { [void]$tuples.AppendLine(',') }
        $arabic = ([string]$row[2]).Replace("'", "''")
        $notes = ([string]$row[3]).Replace("'", "''")
        [void]$tuples.Append("($($row[0]), '$($row[1])', N'$arabic', N'$notes', $($row[4]), '$($row[5])', $($row[6]), $($row[7]))")
    }
    Invoke-SqlFile "INSERT INTO tempdb.dbo.sqlsync_bulk_benchmark (Id, ExternalId, ArabicName, Notes, Amount, ChangedAt, Payload, Enabled) VALUES $tuples;"
}
$literalWatch.Stop()
if ((Get-StageCount) -ne $Rows) { throw 'Literal SQL benchmark did not preserve every row.' }

$bulkSeconds = [Math]::Round($bulkWatch.Elapsed.TotalSeconds, 3)
$literalSeconds = [Math]::Round($literalWatch.Elapsed.TotalSeconds, 3)
$speedup = if ($bulkSeconds -gt 0) { [Math]::Round($literalSeconds / $bulkSeconds, 2) } else { 0 }
if ($speedup -lt $MinimumSpeedup) {
    throw "SqlBulkCopy speedup $speedup was below the required $MinimumSpeedup baseline."
}
$result = [ordered]@{
    rows = $Rows
    bulkSeconds = $bulkSeconds
    literalSqlSeconds = $literalSeconds
    speedup = $speedup
    verifiedRows = Get-StageCount
}
$result | ConvertTo-Json -Compress
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workspace 'result.json') -Encoding utf8

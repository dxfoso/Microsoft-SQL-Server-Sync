[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')]
    [string] $Container,
    [string] $Database = 'AmnDb048',
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_]{1,128}$')]
    [string] $Table
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A stopped Docker engine is no schema evidence. Fail before docker exec or SQL.
$dockerVersion = @(& docker info --format '{{.ServerVersion}}' 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]($dockerVersion -join ''))) {
    throw 'Docker engine is unavailable; isolated schema was not inspected.'
}

$sql = @"
SET NOCOUNT ON;
SELECT 'FK', fk.name, OBJECT_SCHEMA_NAME(fk.parent_object_id),
       OBJECT_NAME(fk.parent_object_id), pc.name,
       OBJECT_SCHEMA_NAME(fk.referenced_object_id),
       OBJECT_NAME(fk.referenced_object_id), rc.name
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
WHERE OBJECT_NAME(fk.parent_object_id) = '$Table'
   OR OBJECT_NAME(fk.referenced_object_id) = '$Table';
SELECT 'INDEX', i.name, i.is_unique, i.is_primary_key, c.name, ic.key_ordinal
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID('dbo.$Table') AND ic.is_included_column = 0
ORDER BY i.index_id, ic.key_ordinal;
"@

$result = @($sql | & docker exec -i $Container bash -lc `
    '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -d "$1" -W -s "|" -h -1' `
    -- $Database)
if ($LASTEXITCODE -ne 0) { throw 'Isolated schema query failed; output is not evidence.' }
[string]($result -join "`n")

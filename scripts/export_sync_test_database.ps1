param(
    [string] $Server = '.\SQLEXPRESS',
    [Parameter(Mandatory = $true)][string] $Database,
    [string] $OutputPath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $backupDirectory = (& sqlcmd -S $Server -E -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultBackupPath'));").Trim()
    if ([string]::IsNullOrWhiteSpace($backupDirectory)) {
        throw 'SQL Server did not report its default backup directory. Pass -OutputPath explicitly.'
    }
    $OutputPath = Join-Path $backupDirectory "$Database-sync-test-copy.bak"
}

$escapedDatabase = $Database.Replace(']', ']]')
$escapedPath = $OutputPath.Replace("'", "''")
& sqlcmd -S $Server -E -b -Q @"
BACKUP DATABASE [$escapedDatabase]
TO DISK = N'$escapedPath'
WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM, STATS = 10;
RESTORE VERIFYONLY FROM DISK = N'$escapedPath' WITH CHECKSUM;
"@
if ($LASTEXITCODE -ne 0) {
    throw "Database backup or verification failed with exit code $LASTEXITCODE."
}

Write-Host "Verified copy-only test backup: $OutputPath"
Write-Warning 'The backup can contain sensitive production data. Keep it outside Git and restrict access.'

[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $SourcePath = '/var/lib/rancher/k3s/storage/pvc-da21dfd0-2ffe-4ba0-9d22-e0a65be0bd3d_velvet-sql-server-sync_sql-sync-postgres-data',
    [string] $BackupRoot = '/var/lib/rancher/k3s/storage-recovery-backups',
    [string] $BackupName = 'sql-sync-postgres-before-wal-recovery-20260904T0100Z'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($SourcePath -notmatch '^/var/lib/rancher/k3s/storage/pvc-[a-f0-9-]+_velvet-sql-server-sync_sql-sync-postgres-data$') {
    throw 'Refusing to back up an unexpected source path.'
}
if ($BackupRoot -ne '/var/lib/rancher/k3s/storage-recovery-backups' -or
    $BackupName -notmatch '^sql-sync-postgres-before-wal-recovery-[0-9TZ]+$') {
    throw 'Refusing to use an unexpected recovery backup target.'
}

$remoteScript = @"
set -euo pipefail
source_path='$SourcePath'
backup_root='$BackupRoot'
backup_path='$BackupRoot/$BackupName'
test -d "`$source_path"
test ! -e "`$backup_path"
install -d -m 0700 -- "`$backup_root"
cp -a --reflink=auto -- "`$source_path" "`$backup_path"
sync
test -f "`$backup_path/PG_VERSION"
source_bytes=`$(du -sb -- "`$source_path" | cut -f1)
backup_bytes=`$(du -sb -- "`$backup_path" | cut -f1)
test "`$source_bytes" = "`$backup_bytes"
printf '{"physicalBackupCreated":true,"sizeVerified":true,"bytes":%s}\n' "`$backup_bytes"
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
& ssh $SshTarget "echo '$encoded' | base64 -d | sudo bash"
if ($LASTEXITCODE -ne 0) { throw 'Physical PostgreSQL volume backup failed.' }

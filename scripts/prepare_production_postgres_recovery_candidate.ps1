[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $BackupPath = '/var/lib/rancher/k3s/storage-recovery-backups/sql-sync-postgres-before-wal-recovery-20260904T0100Z',
    [string] $CandidatePath = '/var/lib/rancher/k3s/storage-recovery-backups/sql-sync-postgres-recovery-candidate-20260904T0100Z'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($BackupPath -ne '/var/lib/rancher/k3s/storage-recovery-backups/sql-sync-postgres-before-wal-recovery-20260904T0100Z' -or
    $CandidatePath -ne '/var/lib/rancher/k3s/storage-recovery-backups/sql-sync-postgres-recovery-candidate-20260904T0100Z') {
    throw 'Refusing unexpected PostgreSQL recovery paths.'
}

$remoteScript = @"
set -euo pipefail
backup_path='$BackupPath'
candidate_path='$CandidatePath'
test -f "`$backup_path/PG_VERSION"
test ! -e "`$candidate_path"
cp -a --reflink=auto -- "`$backup_path" "`$candidate_path"
sync
backup_bytes=`$(du -sb -- "`$backup_path" | cut -f1)
candidate_bytes=`$(du -sb -- "`$candidate_path" | cut -f1)
test "`$backup_bytes" = "`$candidate_bytes"
printf '{"candidateCreated":true,"sizeVerified":true,"bytes":%s}\n' "`$candidate_bytes"
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
& ssh $SshTarget "echo '$encoded' | base64 -d | sudo bash"
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL recovery candidate creation failed.' }

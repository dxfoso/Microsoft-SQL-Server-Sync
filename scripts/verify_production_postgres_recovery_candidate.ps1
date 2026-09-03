[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $PodName = 'sql-sync-postgres-recovery-candidate'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($value in @($Namespace, $PodName)) {
    if ($value -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
        throw "Invalid Kubernetes resource name: $value"
    }
}

& ssh $SshTarget kubectl exec -n $Namespace pod/$PodName -- `
    pg_amcheck -h /tmp -U tru --all --install-missing --parent-check --rootdescend
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL candidate relation/index verification failed.' }

$remoteScript = @'
set -euo pipefail
mkdir -p -m 0700 /candidate/recovery-export
pg_dump -h /tmp -U tru -d sqlsync -Fc -f /candidate/recovery-export/sqlsync.dump
pg_restore --list /candidate/recovery-export/sqlsync.dump >/dev/null
psql -h /tmp -U tru -d sqlsync -v ON_ERROR_STOP=1 -Atc "SELECT json_build_object('databaseReadable', true, 'userTableCount', count(*), 'databaseBytes', pg_database_size(current_database())) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema');"
'@
$remoteScript | & ssh $SshTarget kubectl exec -i -n $Namespace pod/$PodName -- sh
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL candidate logical export verification failed.' }

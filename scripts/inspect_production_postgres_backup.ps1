[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $BackupPath = '/var/lib/rancher/k3s/storage-recovery-backups/sql-sync-postgres-before-wal-recovery-20260904T0100Z',
    [string] $PodName = 'sql-sync-postgres-recovery-inspect',
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Namespace -ne 'velvet-sql-server-sync' -or
    $BackupPath -ne '/var/lib/rancher/k3s/storage-recovery-backups/sql-sync-postgres-before-wal-recovery-20260904T0100Z' -or
    $PodName -ne 'sql-sync-postgres-recovery-inspect') {
    throw 'Refusing unexpected PostgreSQL inspection targets.'
}

$identity = (& ssh $SshTarget "sudo stat -c '%u %g' '$BackupPath'").Trim() -split ' '
if ($LASTEXITCODE -ne 0 -or $identity.Count -ne 2 -or
    $identity[0] -notmatch '^\d+$' -or $identity[1] -notmatch '^\d+$') {
    throw 'Unable to derive the PostgreSQL volume owner identity.'
}
$uid = [int]$identity[0]
$gid = [int]$identity[1]

$manifest = @{
    apiVersion = 'v1'
    kind = 'Pod'
    metadata = @{ name = $PodName; namespace = $Namespace }
    spec = @{
        restartPolicy = 'Never'
        securityContext = @{ runAsUser = $uid; runAsGroup = $gid }
        containers = @(@{
            name = 'inspect'
            image = 'postgres:16-alpine'
            command = @('sh', '-c', 'pg_controldata /backup; pg_resetwal -n -D /backup')
            volumeMounts = @(@{ name = 'backup'; mountPath = '/backup'; readOnly = $true })
        })
        volumes = @(@{
            name = 'backup'
            hostPath = @{ path = $BackupPath; type = 'Directory' }
        })
    }
} | ConvertTo-Json -Depth 12 -Compress

& ssh $SshTarget kubectl delete pod $PodName -n $Namespace --ignore-not-found --wait=true | Out-Null
$manifest | & ssh $SshTarget kubectl apply -n $Namespace -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to create the read-only inspection pod.' }

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    $raw = & ssh $SshTarget kubectl get pod $PodName -n $Namespace -o json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read inspection pod status.' }
    $pod = (($raw -join "`n") | ConvertFrom-Json)
    $phase = [string]$pod.status.phase
    if ($phase -in @('Succeeded', 'Failed')) { break }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)

& ssh $SshTarget kubectl logs pod/$PodName -n $Namespace
if ($phase -ne 'Succeeded') { throw "Inspection pod ended in phase $phase." }

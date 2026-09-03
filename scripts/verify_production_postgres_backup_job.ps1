[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $CronJobName = 'sql-sync-postgres-backup',
    [string] $JobName = 'sql-sync-postgres-backup-verification-20260904',
    [int] $TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($value in @($Namespace, $CronJobName, $JobName)) {
    if ($value -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
        throw "Invalid Kubernetes resource name: $value"
    }
}

& ssh $SshTarget kubectl create job --from=cronjob/$CronJobName $JobName -n $Namespace | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to create the isolated backup verification Job.' }
& ssh $SshTarget kubectl wait job/$JobName -n $Namespace --for=condition=complete `
    --timeout="$($TimeoutSeconds)s" | Out-Null
if ($LASTEXITCODE -ne 0) {
    & ssh $SshTarget kubectl logs job/$JobName -n $Namespace --tail=100
    throw 'The backup verification Job did not complete.'
}
$output = & ssh $SshTarget kubectl logs job/$JobName -n $Namespace --tail=20
if ($LASTEXITCODE -ne 0 -or
    @($output | Where-Object { $_ -like '*"checksumVerified":true*' }).Count -ne 1) {
    throw 'The backup Job did not report a validated logical dump.'
}
$output

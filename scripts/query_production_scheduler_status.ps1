param(
  [string]$SshAlias = 'velvet-leaf-1'
)

$ErrorActionPreference = 'Stop'
$namespace = 'velvet-sql-server-sync'
$remoteScript = @"
set -euo pipefail
kubectl get cronjob sql-sync-auto-tick -n $namespace -o custom-columns=NAME:.metadata.name,SUSPEND:.spec.suspend,LAST:.status.lastScheduleTime,SUCCESS:.status.lastSuccessfulTime,ACTIVE:.status.active[*].name --no-headers
kubectl get jobs -n $namespace --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason,START:.status.startTime,END:.status.completionTime --no-headers | tail -n 12
kubectl logs deployment/sql-sync-back -n $namespace --since=20m --tail=1000 | grep -Ei 'error|exception|auto.sync|tick|durable|diverg|failed' | tail -n 120 || true
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
& ssh $SshAlias "echo $encoded | base64 -d | bash"
if ($LASTEXITCODE -ne 0) {
  throw "Production scheduler status probe failed with exit code $LASTEXITCODE."
}

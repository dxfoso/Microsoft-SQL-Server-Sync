param(
    [string] $RequirePausedOwnerUserId = ''
)

$ErrorActionPreference = 'Stop'
$sshAlias = 'velvet-leaf-1'
$namespace = 'velvet-sql-server-sync'

# Encode one complete remote Bash program so PowerShell, SSH, Bash, kubectl,
# and psql never reinterpret nested SQL quoting at different parser layers.
$remoteScript = @'
set -euo pipefail
kubectl exec -i -n velvet-sql-server-sync deployment/sql-sync-postgres -- \
  psql -v ON_ERROR_STOP=1 -U tru -d sqlsync -AtF '|' <<'SQL'
SELECT 'client', "clientName", "conflictPolicy", "clientVersion", "syncEnabled",
  "isOnline", "sqlConnected", "lastHeartbeat"
FROM agents ORDER BY "ownerUserId", "clientName";
SELECT 'scheduler', "ownerUserId", "manualPendingTables",
  (SELECT count(*) FROM sync_jobs j WHERE j."ownerUserId"=s."ownerUserId"
    AND j.status IN ('queued','waiting','running','snapshotting','uploading','downloading','applying'))
FROM periodic_sync_states s
WHERE "ownerUserId" IN (SELECT DISTINCT "ownerUserId" FROM agents);
SELECT 'table_issue', s."ownerUserId", issue->>'table', issue->>'status',
  issue->>'reason', issue->>'detectedAt', issue->>'message'
FROM periodic_sync_states s
CROSS JOIN LATERAL jsonb_array_elements(COALESCE(NULLIF(s."tableIssues", ''), '[]')::jsonb) issue
WHERE issue->>'status' IN ('needs_input', 'resolving')
ORDER BY s."ownerUserId", issue->>'table';
SELECT 'recent_failed_job', "ownerUserId", "table", "clientName", direction,
  status, "updatedAt", COALESCE(error, '')
FROM sync_jobs
WHERE status='failed'
  AND NULLIF("updatedAt", '')::timestamptz >= CURRENT_TIMESTAMP - INTERVAL '24 hours'
ORDER BY "updatedAt" DESC LIMIT 50;
SELECT 'authoritative_history', issue->>'table', issue->>'sourceClientName',
  issue->>'targetClientNames', issue->>'updatedAt'
FROM periodic_sync_states s
CROSS JOIN LATERAL jsonb_array_elements(COALESCE(NULLIF(s."tableIssues", ''), '[]')::jsonb) issue
WHERE issue->>'action'='authoritative_reconcile' AND issue->>'status'='ready'
ORDER BY issue->>'updatedAt' DESC LIMIT 20;
SQL
'@
$encodedScript = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($remoteScript)
)

$output = & ssh $sshAlias "echo '$encodedScript' | base64 -d | bash"
if ($LASTEXITCODE -ne 0) {
    throw "Production conflict-policy query failed through $sshAlias in namespace $namespace."
}
$requiredOwner = $RequirePausedOwnerUserId.Trim()
if (-not [string]::IsNullOrWhiteSpace($requiredOwner)) {
    $schedulerRows = @($output | Where-Object { $_ -like "scheduler|$requiredOwner|*" })
    if ($schedulerRows.Count -ne 1) {
        throw "Expected exactly one scheduler row for paused owner $requiredOwner, found $($schedulerRows.Count)."
    }
    $fields = @($schedulerRows[0] -split '\|', 4)
    if ($fields.Count -ne 4 -or
        $fields[2] -ne '["__automatic_sync_paused__"]' -or
        $fields[3] -ne '0') {
        throw "Owner $requiredOwner is not safely paused with zero active jobs: $($schedulerRows[0])"
    }
}
$output

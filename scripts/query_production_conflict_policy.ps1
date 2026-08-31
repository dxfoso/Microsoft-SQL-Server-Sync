param()

$ErrorActionPreference = 'Stop'
$sshAlias = 'velvet-leaf-1'
$namespace = 'velvet-sql-server-sync'

# Encode one complete remote Bash program so PowerShell, SSH, Bash, kubectl,
# and psql never reinterpret nested SQL quoting at different parser layers.
$remoteScript = @'
set -euo pipefail
kubectl exec -n velvet-sql-server-sync deployment/sql-sync-postgres -- \
  psql -U tru -d sqlsync -AtF '|' -c \
  'SELECT "clientName", "conflictPolicy", "clientVersion", "isOnline", "sqlConnected" FROM agents ORDER BY "ownerUserId", "clientName";'
'@
$encodedScript = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($remoteScript)
)

$output = & ssh $sshAlias "echo '$encodedScript' | base64 -d | bash"
if ($LASTEXITCODE -ne 0) {
    throw "Production conflict-policy query failed through $sshAlias in namespace $namespace."
}
$output

[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync'
)

$ErrorActionPreference = 'Stop'
if ($Namespace -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
    throw "Invalid Kubernetes namespace: $Namespace"
}

# The remote template iterates over .data only to emit each key name. It never
# renders $value, so secret contents do not cross SSH or enter local logs.
$remoteScript = @'
set -euo pipefail
namespace="$1"
kubectl get secrets -n "$namespace" -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{range $key, $_ := .data}}{{$key}}{{"\t"}}{{end}}{{"\n"}}{{end}}'
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
& ssh $SshTarget "echo '$encoded' | base64 -d | bash -s -- '$Namespace'"
if ($LASTEXITCODE -ne 0) {
    throw "Secret metadata query failed with exit code $LASTEXITCODE."
}

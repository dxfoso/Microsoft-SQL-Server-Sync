[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $SecretName = 'cloud-repo-ebbd5457-token',
    [string] $ServiceAccountName = 'cloud-repo-ebbd5457'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Namespace -ne 'velvet-sql-server-sync' -or
    $SecretName -ne 'cloud-repo-ebbd5457-token' -or
    $ServiceAccountName -ne 'cloud-repo-ebbd5457') {
    throw 'Refusing unexpected service-account token targets.'
}

$remoteScript = @'
set -euo pipefail
namespace="$1"
secret_name="$2"
kubectl get secret "$secret_name" -n "$namespace" --ignore-not-found \
  -o go-template='{{.type}}{{"|"}}{{index .metadata.annotations "kubernetes.io/service-account.name"}}'
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
$metadataLines = & ssh $SshTarget "echo '$encoded' | base64 -d | bash -s -- '$Namespace' '$SecretName'"
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect service-account token metadata.' }
$metadata = [string]($metadataLines -join '')
if (-not [string]::IsNullOrWhiteSpace($metadata)) {
    if ($metadata -ne "kubernetes.io/service-account-token|$ServiceAccountName") {
        throw 'Refusing to delete a Secret that is not the exact expected service-account token.'
    }
    & ssh $SshTarget kubectl delete secret $SecretName -n $Namespace | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to revoke the service-account token.' }
}

$absentLines = & ssh $SshTarget kubectl get secret $SecretName -n $Namespace `
    --ignore-not-found -o 'jsonpath={.metadata.name}'
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify service-account token revocation.' }
$remainingName = [string]($absentLines -join '')
if (-not [string]::IsNullOrWhiteSpace($remainingName)) {
    throw 'Service-account token still exists after revocation.'
}
@{ serviceAccountTokenRevoked = $true } | ConvertTo-Json -Compress

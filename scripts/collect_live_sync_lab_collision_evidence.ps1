[CmdletBinding()]
param(
  [long]$BaselineVersion = 4525,
  [string]$Database = 'AmnDb048_SyncLab',
  [string[]]$ClientNames = @('alshallan2', 'velvet factory'),
  [string]$OutputDirectory = '',
  [ValidateSet('full_backup', 'change_tracking_delta')][string]$Mode = 'change_tracking_delta'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$namespace = 'velvet-sql-server-sync'
$sshAlias = 'velvet-leaf-1'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
  $OutputDirectory = Join-Path $repoRoot "artifacts/sync-lab-collision/$stamp"
}

$adminSecretJson = (& ssh $sshAlias "kubectl get secret sync-auto-scheduler -n $namespace -o json" | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the namespace-scoped scheduler credential.' }
$adminSecret = $adminSecretJson | ConvertFrom-Json
$adminName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($adminSecret.data.ADMIN_NAME))
$adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($adminSecret.data.ADMIN_PASSWORD))

$exportSecretJson = (& ssh $sshAlias "kubectl get secret sql-sync-private-export -n $namespace -o json" | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the namespace-scoped private-export credential.' }
$exportSecret = $exportSecretJson | ConvertFrom-Json
$uploadToken = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($exportSecret.data.token))

$collectorArguments = @{
  AdminUsername = $adminName
  AdminPassword = $adminPassword
  UploadToken = $uploadToken
  Database = $Database
  SshTarget = $sshAlias
  Namespace = $namespace
  OutputDirectory = $OutputDirectory
  OnlyClient = $ClientNames
  ForceFresh = $true
  Mode = $Mode
  TimeoutMinutes = 60
}
if ($Mode -eq 'change_tracking_delta') {
  $collectorArguments.BaselineVersion = $BaselineVersion
}
& (Join-Path $PSScriptRoot 'collect_live_client_database_copies.ps1') @collectorArguments
if ($LASTEXITCODE -ne 0) { throw 'Collision evidence collection failed.' }

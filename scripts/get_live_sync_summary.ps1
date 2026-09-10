[CmdletBinding()]
param(
  [string]$SshAlias = 'velvet-leaf-1',
  [string]$Namespace = 'velvet-sql-server-sync',
  [string]$SecretName = 'sync-auto-scheduler',
  [string]$BaseUrl = 'https://sync.velvet-leaf.com',
  [string[]]$ClientNames = @('alshallan2', 'velvet factory'),
  [string[]]$Tables = @('ac000', 'bi000', 'bu000', 'ce000', 'cp000', 'en000', 'er000', 'ms000', 'mt000', 'pt000')
)

$ErrorActionPreference = 'Stop'

function Invoke-ControlPlaneFunction {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][hashtable]$Arguments
  )

  $body = @{ name = $Name; args = $Arguments } | ConvertTo-Json -Depth 6 -Compress
  $response = Invoke-RestMethod -Method Post -Uri "$($BaseUrl.TrimEnd('/'))/call" -ContentType 'application/json' -Body $body
  if ($response.status -eq 'failed') {
    throw "Control-plane function $Name failed."
  }
  return $response.value
}

$secretJson = (& ssh $SshAlias "kubectl get secret $SecretName -n $Namespace -o json" | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw 'Could not read the namespace-scoped scheduler credential.'
}
$secret = $secretJson | ConvertFrom-Json
$adminName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.ADMIN_NAME))
$adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.ADMIN_PASSWORD))

$login = Invoke-ControlPlaneFunction -Name 'auth_login' -Arguments @{
  name = $adminName
  password = $adminPassword
  app = 'web'
}
$token = [string]$login.token
if ([string]::IsNullOrWhiteSpace($token)) {
  throw 'Administrator login returned no session token.'
}

$state = Invoke-ControlPlaneFunction -Name 'live_state' -Arguments @{ token = $token }
$activeStatuses = @('queued', 'waiting', 'running', 'snapshotting', 'uploading', 'downloading', 'applying')
$activeJobs = @($state.jobs | Where-Object { $_.status -in $activeStatuses })
$failedJobs = @($state.jobs | Where-Object { $_.status -in @('failed', 'error') })
$agents = @($state.agents | Where-Object { $_.clientName -in $ClientNames })

$tableChecks = @()
foreach ($tableName in $Tables) {
  $states = @()
  foreach ($agent in $agents) {
    $agentDatabase = [string]$agent.database
    $tableState = @($agent.tables | Where-Object {
      $tableParts = @($_.table -split '::')
      $tableParts.Count -ge 2 -and
        $tableParts[0] -ieq $agentDatabase -and
        $tableParts[-1] -ieq $tableName
    })[0]
    $states += [pscustomobject]@{
      clientName = $agent.clientName
      rowCount = $tableState.rowCount
      checksum = $tableState.tableChecksum
      status = $tableState.status
      localChangesPending = $tableState.localChangesPending
    }
  }
  $rowCounts = @($states | Select-Object -ExpandProperty rowCount -Unique)
  $checksums = @($states | Select-Object -ExpandProperty checksum -Unique)
  $tableChecks += [pscustomobject]@{
    table = $tableName
    rowCount = if ($rowCounts.Count -eq 1) { $rowCounts[0] } else { $null }
    rowsEqual = $states.Count -eq $ClientNames.Count -and $rowCounts.Count -eq 1
    checksumEqual = $states.Count -eq $ClientNames.Count -and $checksums.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$checksums[0])
    completed = @($states | Where-Object { $_.status -ne 'Completed' }).Count -eq 0
    pending = @($states | Where-Object { $_.localChangesPending }).Count -gt 0
  }
}

$agentSummary = @($agents | ForEach-Object {
  [pscustomobject]@{
    clientName = $_.clientName
    database = $_.database
    online = $_.isOnline
    serverConnected = $_.serverConnected
    sqlConnected = $_.sqlConnected
    syncEnabled = $_.syncEnabled
    clientVersion = $_.clientVersion
    automaticNumberIncidentCount = $_.automaticNumberIncidentCount
    diagnosticStatus = $_.diagnostics.status
    diagnosticStage = $_.diagnostics.stage
    diagnosticProgressPercent = $_.diagnostics.progressPercent
    fingerprintAuditStatus = $_.fingerprintAudit.status
    fingerprintAuditCheckedTables = $_.fingerprintAudit.checkedTables
    fingerprintAuditTotalTables = $_.fingerprintAudit.totalTables
    fingerprintAuditCurrentTables = @($_.fingerprintAudit.currentTables)
  }
})

[pscustomobject]@{
  automaticSyncPaused = $state.automaticSyncPaused
  gateStatus = $state.syncGate.status
  # The issue list intentionally retains resolved audit rows. Use the server's
  # active count so a ready gate never looks blocked in operational summaries.
  gateIssueCount = [int]$state.syncGate.issueCount
  activeJobCount = $activeJobs.Count
  failedJobCount = $failedJobs.Count
  allConverged = @($tableChecks | Where-Object { -not $_.rowsEqual -or -not $_.checksumEqual -or -not $_.completed -or $_.pending }).Count -eq 0
  agents = $agentSummary
  tables = $tableChecks
} | ConvertTo-Json -Depth 6

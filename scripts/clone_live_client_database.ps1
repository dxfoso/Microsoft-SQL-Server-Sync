[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SourceClient,
    [Parameter(Mandatory = $true)][string] $TargetClient,
    [string] $Database = 'AmnDb048',
    [string] $BaseUrl = 'https://sync.velvet-leaf.com',
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [ValidateRange(10, 1440)][int] $TimeoutMinutes = 360,
    [switch] $ReuseCompletedSourceBackup,
    [string] $OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($SourceClient.Trim().Equals($TargetClient.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and target clients must be different.'
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path $repoRoot "artifacts/database-clones/$stamp"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts'))
if (-not $OutputDirectory.StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must stay inside $artifactRoot"
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Read-SecretObject([string] $Name) {
    $lines = @(& ssh $SshTarget "kubectl get secret $Name -n $Namespace -o json")
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
        throw "Unable to read required Secret metadata for $Name."
    }
    try { return (($lines -join "`n") | ConvertFrom-Json) }
    catch { throw "Unable to parse required Secret $Name; details suppressed." }
}

function Read-SecretValue([object] $Secret, [string] $Key) {
    $property = $Secret.data.PSObject.Properties[$Key]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Required Secret key is unavailable: $Key"
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$property.Value))
}

function Invoke-ControlPlane([string] $Name, [hashtable] $Arguments) {
    $body = @{ name = $Name; args = $Arguments } | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-RestMethod -Method Post -Uri "$($BaseUrl.TrimEnd('/'))/call" `
        -ContentType 'application/json' -Body $body -TimeoutSec 90
    if ($response.status -eq 'failed') {
        $message = [string]$response.error
        if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$response.message }
        throw "${Name}: $message"
    }
    if ($response.status -eq 'success' -and $null -ne $response.value) { return $response.value }
    return $response
}

function Find-Agent([object] $State, [string] $ClientName) {
    return @($State.agents | Where-Object {
        ([string]$_.clientName).Equals($ClientName, [StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
}

function Assert-ClonePreconditions([object] $State) {
    $source = Find-Agent $State $SourceClient
    $target = Find-Agent $State $TargetClient
    if ($null -eq $source -or $source.isOnline -ne $true -or $source.sqlConnected -ne $true) {
        throw 'Source client is not online and SQL-connected.'
    }
    if ($null -eq $target -or $target.isOnline -ne $true -or $target.sqlConnected -ne $true) {
        throw 'Target client is not online and SQL-connected.'
    }
    if (-not ([string]$source.database).Equals($Database, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$target.database).Equals($Database, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and target must both select the requested database.'
    }
    if ($target.syncEnabled -ne $false) {
        throw 'Target synchronization must be disabled before replacement.'
    }
    $active = @('queued', 'waiting', 'running', 'snapshotting', 'uploading', 'downloading', 'applying')
    $targetJobs = @($State.jobs | Where-Object {
        ([string]$_.clientName).Equals($TargetClient, [StringComparison]::OrdinalIgnoreCase) -and
        $active -contains ([string]$_.status).Trim().ToLowerInvariant()
    })
    if ($targetJobs.Count -ne 0) { throw 'Target client still has active synchronization jobs.' }
    $sourceJobs = @($State.jobs | Where-Object {
        ([string]$_.clientName).Equals($SourceClient, [StringComparison]::OrdinalIgnoreCase) -and
        $active -contains ([string]$_.status).Trim().ToLowerInvariant()
    })
    if ($sourceJobs.Count -ne 0) { throw 'Source client still has active synchronization jobs.' }
}

function Wait-ForExport([string] $ClientName, [string] $RequestId, [DateTime] $Deadline) {
    while ([DateTime]::UtcNow -lt $Deadline) {
        $state = Invoke-ControlPlane 'live_state' @{ token = $script:sessionToken }
        $agent = Find-Agent $state $ClientName
        if ($null -eq $agent) { throw "Client disappeared while waiting: $ClientName" }
        $operation = $agent.dataExport
        if ([string]$operation.requestId -eq $RequestId) {
            $status = ([string]$operation.status).Trim().ToLowerInvariant()
            if ($status -eq 'completed') { return $operation }
            if ($status -eq 'failed') { throw "$ClientName operation failed: $($operation.message)" }
        }
        Start-Sleep -Seconds 20
    }
    throw "$ClientName database operation timed out."
}

$schedulerSecret = Read-SecretObject 'sync-auto-scheduler'
$exportSecret = Read-SecretObject 'sql-sync-private-export'
$adminName = Read-SecretValue $schedulerSecret 'ADMIN_NAME'
$adminPassword = Read-SecretValue $schedulerSecret 'ADMIN_PASSWORD'
$privateToken = Read-SecretValue $exportSecret 'token'

try {
    $login = Invoke-ControlPlane 'auth_login' @{
        name = $adminName
        password = $adminPassword
        app = 'web'
    }
    $script:sessionToken = [string]$login.token
    if ([string]::IsNullOrWhiteSpace($script:sessionToken)) { throw 'Login returned no token.' }
    $state = Invoke-ControlPlane 'live_state' @{ token = $script:sessionToken }
    Assert-ClonePreconditions $state
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)

    if ($ReuseCompletedSourceBackup) {
        $sourceAgent = Find-Agent $state $SourceClient
        $sourceResult = $sourceAgent.dataExport
        $sourceRequestId = [string]$sourceResult.requestId
        $sourceStatus = ([string]$sourceResult.status).Trim().ToLowerInvariant()
        $sourceMode = ([string]$sourceResult.mode).Trim().ToLowerInvariant()
        $sourceSha256 = [string]$sourceResult.sha256
        if ($sourceStatus -ne 'completed' -or $sourceMode -ne 'full_backup' -or
            [string]::IsNullOrWhiteSpace($sourceRequestId) -or [long]$sourceResult.bytes -le 0 -or
            [int]$sourceResult.chunkCount -le 0 -or $sourceSha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'Source has no completed verified full backup export to reuse.'
        }
    }
    else {
        $sourceRequest = Invoke-ControlPlane 'agent_data_export_request' @{
            clientName = $SourceClient
            database = $Database
            uploadUrl = "$($BaseUrl.TrimEnd('/'))/private-export"
            uploadToken = $privateToken
            mode = 'full_backup'
            token = $script:sessionToken
        }
        $sourceRequestId = [string]$sourceRequest.dataExport.requestId
        if ([string]::IsNullOrWhiteSpace($sourceRequestId)) { throw 'Source backup request returned no ID.' }
        $sourceResult = Wait-ForExport $SourceClient $sourceRequestId $deadline
    }

    $state = Invoke-ControlPlane 'live_state' @{ token = $script:sessionToken }
    Assert-ClonePreconditions $state
    $restoreRequest = Invoke-ControlPlane 'agent_database_clone_request' @{
        sourceClientName = $SourceClient
        targetClientName = $TargetClient
        database = $Database
        downloadUrl = "$($BaseUrl.TrimEnd('/'))/private-export"
        downloadToken = $privateToken
        token = $script:sessionToken
    }
    $restoreRequestId = [string]$restoreRequest.dataExport.requestId
    if ([string]::IsNullOrWhiteSpace($restoreRequestId)) { throw 'Target restore request returned no ID.' }
    $restoreResult = Wait-ForExport $TargetClient $restoreRequestId $deadline

    $summary = [ordered]@{
        completed = $true
        sourceClient = $SourceClient
        targetClient = $TargetClient
        database = $Database
        sourceRequestId = $sourceRequestId
        restoreRequestId = $restoreRequestId
        bytes = [long]$sourceResult.bytes
        sha256 = [string]$sourceResult.sha256
        chunkCount = [int]$sourceResult.chunkCount
        restoreMessage = [string]$restoreResult.message
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $summaryPath = Join-Path $OutputDirectory 'summary.json'
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    [pscustomobject]$summary | Format-List
    Write-Host "Verified database clone completed: $summaryPath"
}
finally {
    Remove-Variable adminPassword, privateToken, sessionToken -Scope Script -ErrorAction SilentlyContinue
}

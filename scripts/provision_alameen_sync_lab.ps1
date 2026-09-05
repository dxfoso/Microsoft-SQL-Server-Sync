[CmdletBinding()]
param(
    [string] $SourceClient = 'velvet factory',
    [string[]] $TargetClients = @('alshallan2', 'velvet factory'),
    [string] $SourceDatabase = 'AmnDb048',
    [string] $LabDatabase = 'AmnDb048_SyncLab',
    [string] $BaseUrl = 'https://sync.velvet-leaf.com',
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [ValidateRange(10, 1440)][int] $TimeoutMinutes = 360,
    [string] $OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path $repoRoot "artifacts/alameen-labs/$stamp"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts'))
if (-not $OutputDirectory.StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must stay inside $artifactRoot"
}
if (-not $LabDatabase.Equals("${SourceDatabase}_SyncLab", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'LabDatabase must be the source database name plus _SyncLab.'
}
if ($TargetClients.Count -eq 0 -or @($TargetClients | Select-Object -Unique).Count -ne $TargetClients.Count) {
    throw 'TargetClients must contain distinct client names.'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Read-SecretObject([string] $Name) {
    $lines = @(& ssh $SshTarget "kubectl get secret $Name -n $Namespace -o json")
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { throw "Unable to read required Secret metadata for $Name." }
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
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90
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

function Assert-LabPreconditions([object] $State) {
    foreach ($clientName in @($SourceClient) + $TargetClients) {
        $agent = Find-Agent $State $clientName
        if ($null -eq $agent -or $agent.isOnline -ne $true -or $agent.sqlConnected -ne $true) {
            throw "Client is not online and SQL-connected: $clientName"
        }
        if ($agent.syncEnabled -ne $false) { throw "Synchronization must be disabled: $clientName" }
    }
    $source = Find-Agent $State $SourceClient
    if (-not ([string]$source.database).Equals($SourceDatabase, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The source client does not select the required source database.'
    }
    $active = @('queued', 'waiting', 'running', 'snapshotting', 'uploading', 'downloading', 'applying')
    $inScope = @($State.jobs | Where-Object {
        $active -contains ([string]$_.status).Trim().ToLowerInvariant() -and
        $TargetClients -contains [string]$_.clientName
    })
    if ($inScope.Count -ne 0) { throw 'A target client still has an active synchronization job.' }
}

function Wait-ForLabRestore([string] $ClientName, [string] $RequestId, [DateTime] $Deadline) {
    while ([DateTime]::UtcNow -lt $Deadline) {
        $state = Invoke-ControlPlane 'live_state' @{ token = $script:sessionToken }
        $agent = Find-Agent $state $ClientName
        if ($null -eq $agent) { throw "Client disappeared while waiting: $ClientName" }
        $operation = $agent.dataExport
        if ([string]$operation.requestId -eq $RequestId) {
            $status = ([string]$operation.status).Trim().ToLowerInvariant()
            if ($status -eq 'completed') { return $operation }
            if ($status -eq 'failed') { throw "$ClientName lab restore failed: $($operation.message)" }
        }
        Start-Sleep -Seconds 20
    }
    throw "$ClientName lab restore timed out."
}

$schedulerSecret = Read-SecretObject 'sync-auto-scheduler'
$exportSecret = Read-SecretObject 'sql-sync-private-export'
$adminName = Read-SecretValue $schedulerSecret 'ADMIN_NAME'
$adminPassword = Read-SecretValue $schedulerSecret 'ADMIN_PASSWORD'
$privateToken = Read-SecretValue $exportSecret 'token'
$script:sessionToken = ''

try {
    $login = Invoke-ControlPlane 'auth_login' @{ name = $adminName; password = $adminPassword; app = 'web' }
    $script:sessionToken = [string]$login.token
    if ([string]::IsNullOrWhiteSpace($script:sessionToken)) { throw 'Login returned no token.' }
    $state = Invoke-ControlPlane 'live_state' @{ token = $script:sessionToken }
    Assert-LabPreconditions $state
    $source = Find-Agent $state $SourceClient
    $sourceExport = $source.dataExport
    if (([string]$sourceExport.status).ToLowerInvariant() -ne 'completed' -or
        ([string]$sourceExport.mode).ToLowerInvariant() -ne 'full_backup' -or
        [long]$sourceExport.bytes -le 0 -or [int]$sourceExport.chunkCount -le 0 -or
        [string]$sourceExport.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The source has no completed verified full backup to reuse.'
    }
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $results = @()
    foreach ($targetClient in $TargetClients) {
        $state = Invoke-ControlPlane 'live_state' @{ token = $script:sessionToken }
        Assert-LabPreconditions $state
        $request = Invoke-ControlPlane 'agent_database_lab_restore_request' @{
            sourceClientName = $SourceClient
            targetClientName = $targetClient
            database = $SourceDatabase
            targetDatabase = $LabDatabase
            downloadUrl = "$($BaseUrl.TrimEnd('/'))/private-export"
            downloadToken = $privateToken
            token = $script:sessionToken
        }
        $requestId = [string]$request.dataExport.requestId
        if ([string]::IsNullOrWhiteSpace($requestId)) { throw 'Lab restore request returned no ID.' }
        $result = Wait-ForLabRestore $targetClient $requestId $deadline
        $results += [pscustomobject]@{
            clientName = $targetClient
            requestId = $requestId
            status = [string]$result.status
            message = [string]$result.message
        }
    }
    $summary = [ordered]@{
        completed = $true
        sourceClient = $SourceClient
        sourceDatabase = $SourceDatabase
        labDatabase = $LabDatabase
        sourceRequestId = [string]$sourceExport.requestId
        bytes = [long]$sourceExport.bytes
        sha256 = [string]$sourceExport.sha256
        chunkCount = [int]$sourceExport.chunkCount
        clients = $results
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $summaryPath = Join-Path $OutputDirectory 'summary.json'
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    [pscustomobject]$summary | Format-List
    Write-Host "Isolated Al-Ameen lab provisioning completed: $summaryPath"
}
finally {
    if ($script:sessionToken) {
        try { $null = Invoke-ControlPlane 'auth_logout' @{ token = $script:sessionToken } } catch {}
    }
    Remove-Variable adminPassword, privateToken, sessionToken -Scope Script -ErrorAction SilentlyContinue
}

[CmdletBinding()]
param(
    [long] $BaselineVersion = 5796,
    [string] $ClientName = 'alshallan2',
    [string] $Database = 'AmnDb048',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $BaseUrl = 'https://sync.velvet-leaf.com'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$outputDirectory = Join-Path $repoRoot "artifacts/alameen-lab/material-prechange-baseline-$stamp"

function Read-SecretObject {
    param([string] $Name)
    $lines = @(& ssh $SshTarget "kubectl get secret $Name -n $Namespace -o json")
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
        throw "Unable to read required production Secret metadata for $Name."
    }
    try { return (($lines -join "`n") | ConvertFrom-Json) }
    catch { throw "Unable to parse required production Secret $Name; details suppressed." }
}

function Read-SecretValue {
    param([object] $Secret, [string] $Key)
    $property = $Secret.data.PSObject.Properties[$Key]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Required Secret key is unavailable: $Key"
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$property.Value))
}

function Invoke-ControlPlane {
    param([string] $Name, [hashtable] $Arguments)
    $body = @{ name = $Name; args = $Arguments } | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-RestMethod -Method Post -Uri "$($BaseUrl.TrimEnd('/'))/call" `
        -ContentType 'application/json' -Body $body -TimeoutSec 60
    if ($response.status -eq 'failed') { throw "$Name failed; response details suppressed." }
    if ($response.status -eq 'success' -and $null -ne $response.value) { return $response.value }
    return $response
}

$schedulerSecret = Read-SecretObject -Name 'sync-auto-scheduler'
$exportSecret = Read-SecretObject -Name 'sql-sync-private-export'
$adminName = Read-SecretValue -Secret $schedulerSecret -Key 'ADMIN_NAME'
$adminPassword = Read-SecretValue -Secret $schedulerSecret -Key 'ADMIN_PASSWORD'
$uploadToken = Read-SecretValue -Secret $exportSecret -Key 'token'

try {
    $login = Invoke-ControlPlane -Name 'auth_login' -Arguments @{
        name = $adminName
        password = $adminPassword
        app = 'web'
    }
    $sessionToken = [string]$login.token
    if ([string]::IsNullOrWhiteSpace($sessionToken)) { throw 'Login returned no session token.' }
    $state = Invoke-ControlPlane -Name 'live_state' -Arguments @{ token = $sessionToken }
    $client = @($state.agents | Where-Object {
        [string]$_.clientName -eq $ClientName
    }) | Select-Object -First 1
    if ($null -eq $client -or $client.isOnline -ne $true -or $client.sqlConnected -ne $true) {
        throw "$ClientName is not online and SQL-connected."
    }
    if ($client.syncEnabled -ne $false) {
        throw "$ClientName synchronization must be disabled before the material experiment."
    }
    $activeStatuses = @('queued', 'waiting', 'running', 'snapshotting', 'uploading', 'downloading', 'applying')
    $activeJobs = @($state.jobs | Where-Object {
        [string]$_.clientName -eq $ClientName -and
        $activeStatuses -contains ([string]$_.status).Trim().ToLowerInvariant()
    })
    if ($activeJobs.Count -ne 0) { throw "$ClientName still has active synchronization jobs." }

    & (Join-Path $PSScriptRoot 'collect_live_client_database_copies.ps1') `
        -AdminUsername $adminName -AdminPassword $adminPassword `
        -UploadToken $uploadToken -Database $Database -BaseUrl $BaseUrl `
        -SshTarget $SshTarget -Namespace $Namespace -OutputDirectory $outputDirectory `
        -OnlyClient $ClientName -ForceFresh -Mode change_tracking_delta `
        -BaselineVersion $BaselineVersion -TimeoutMinutes 30 -MaxExportAttempts 3
    if ($LASTEXITCODE -ne 0) { throw 'Material pre-change baseline export failed.' }

    $summaryPath = Join-Path $outputDirectory 'summary.json'
    $summary = @(Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json)[0]
    [pscustomobject]@{
        prepared = $true
        clientName = $ClientName
        database = $Database
        syncEnabled = $false
        activeSyncJobs = 0
        priorBaselineVersion = [long]$summary.baselineVersion
        materialBaselineVersion = [long]$summary.upperVersion
        capturedChangeCount = [long]$summary.changeCount
        bytes = [long]$summary.bytes
        sha256 = [string]$summary.sha256
        outputDirectory = $outputDirectory
    } | ConvertTo-Json -Compress
}
finally {
    Remove-Variable adminPassword, uploadToken, sessionToken -ErrorAction SilentlyContinue
}

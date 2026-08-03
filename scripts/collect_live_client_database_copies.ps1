[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $AdminUsername,
    [Parameter(Mandatory = $true)][string] $AdminPassword,
    [Parameter(Mandatory = $true)][ValidateLength(32, 256)][string] $UploadToken,
    [string] $Database = 'AmnDb048',
    [string] $BaseUrl = 'https://sync.velvet-leaf.com',
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $OutputDirectory = '',
    [int] $TimeoutMinutes = 240
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path $repoRoot "artifacts/live-client-copies/$stamp"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts'))
if (-not $OutputDirectory.StartsWith($artifactsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must stay inside $artifactsRoot"
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Invoke-ControlPlaneFunction {
    param([string] $Name, [hashtable] $Arguments)
    $body = @{ name = $Name; args = $Arguments } | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-RestMethod -Method Post -Uri "$($BaseUrl.TrimEnd('/'))/call" -ContentType 'application/json' -Body $body -TimeoutSec 60
    if ($response.status -eq 'failed') {
        $detail = [string]$response.error
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = [string]$response.message }
        throw "${Name}: $detail"
    }
    if ($response.status -eq 'success' -and $null -ne $response.value) {
        return $response.value
    }
    return $response
}

function Get-ClientKey([string] $ClientName) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ClientName))
    return $encoded.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Invoke-SshText([string] $Command) {
    $lines = & ssh $SshTarget $Command
    if ($LASTEXITCODE -ne 0) { throw "SSH command failed: $Command" }
    return @($lines)
}

function Copy-PrivateArtifact {
    param(
        [string] $Pod,
        [string] $PodDirectory,
        [string] $Artifact,
        [string] $LocalDirectory,
        [string] $RequestId
    )
    if ($Artifact -notmatch '^(\d{8}\.part|manifest\.json)$') {
        throw "Unsafe export artifact name: $Artifact"
    }
    $remoteTemp = "/home/dxfoso/sql-sync-export-$RequestId-$Artifact"
    $localPath = Join-Path $LocalDirectory $Artifact
    Invoke-SshText "kubectl cp -n $Namespace '$Pod`:$PodDirectory/$Artifact' '$remoteTemp'" | Out-Null
    & scp "${SshTarget}:$remoteTemp" $localPath
    if ($LASTEXITCODE -ne 0) { throw "SCP failed for $Artifact" }
    $remoteHashLines = @(Invoke-SshText "sha256sum '$remoteTemp'")
    if ($remoteHashLines.Count -eq 0) { throw "Remote checksum returned no output for $Artifact" }
    $remoteHash = ([string]$remoteHashLines[0]).Split(' ')[0].Trim().ToLowerInvariant()
    $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash.ToLowerInvariant()
    if ($remoteHash -ne $localHash) { throw "Checksum mismatch while copying $Artifact" }
    Invoke-SshText "kubectl exec -n $Namespace '$Pod' -- rm -f '$PodDirectory/$Artifact'" | Out-Null
    Invoke-SshText "rm -f '$remoteTemp'" | Out-Null
}

$login = Invoke-ControlPlaneFunction 'auth_login' @{
    name = $AdminUsername
    email = $AdminUsername
    password = $AdminPassword
    app = 'web'
}
$sessionToken = [string]$login.token
if ([string]::IsNullOrWhiteSpace($sessionToken)) { throw 'Control-plane login returned no token.' }

$initialState = Invoke-ControlPlaneFunction 'live_state' @{ token = $sessionToken }
$clients = @($initialState.agents | Where-Object {
    $_.isOnline -eq $true -and
    $_.sqlConnected -eq $true -and
    ([string]$_.database).Trim().Equals($Database, [StringComparison]::OrdinalIgnoreCase)
})
if ($clients.Count -eq 0) { throw "No online SQL-connected clients selected $Database." }

$summary = @()
foreach ($client in $clients) {
    $clientName = [string]$client.clientName
    $existingExport = $client.dataExport
    $existingRequestId = if ($null -eq $existingExport) { '' } else { [string]$existingExport.requestId }
    $existingStatus = if ($null -eq $existingExport) { '' } else { ([string]$existingExport.status).Trim().ToLowerInvariant() }
    $canResume = $existingRequestId -match '^[A-Za-z0-9._-]{1,64}$' -and @('requested', 'running', 'client_offline') -contains $existingStatus
    if ($canResume) {
        $requestId = $existingRequestId
        Write-Host "Resuming pending read-only export $requestId for $clientName."
    } else {
        $request = Invoke-ControlPlaneFunction 'agent_data_export_request' @{
            clientName = $clientName
            database = $Database
            uploadUrl = "$($BaseUrl.TrimEnd('/'))/private-export"
            uploadToken = $UploadToken
            token = $sessionToken
        }
        $requestId = [string]$request.dataExport.requestId
    }
    if ($requestId -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw "Invalid request id for $clientName" }
    $clientKey = Get-ClientKey $clientName
    $clientDirectory = Join-Path $OutputDirectory $clientKey
    New-Item -ItemType Directory -Force -Path $clientDirectory | Out-Null
    $copied = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $manifestCopied = $false

    while ([DateTime]::UtcNow -lt $deadline -and -not $manifestCopied) {
        $podLines = @(Invoke-SshText "kubectl get pods -n $Namespace -l app.kubernetes.io/component=frontend -o jsonpath='{.items[0].metadata.name}'")
        if ($podLines.Count -eq 0) { throw 'Frontend pod query returned no output.' }
        $pod = ([string]$podLines[0]).Trim()
        if ([string]::IsNullOrWhiteSpace($pod)) { throw 'Frontend pod was not found.' }
        $podDirectory = "/app/data/client-updates/.private-exports/$requestId/$clientKey"
        $available = Invoke-SshText "kubectl exec -n $Namespace '$pod' -- sh -c 'if [ -d `"$podDirectory`" ]; then ls -1 `"$podDirectory`" | sort; fi'"
        foreach ($artifact in @($available | Where-Object { $_ -match '^\d{8}\.part$' })) {
            if ($copied.Add($artifact)) {
                Copy-PrivateArtifact -Pod $pod -PodDirectory $podDirectory -Artifact $artifact -LocalDirectory $clientDirectory -RequestId $requestId
            }
        }
        if ($available -contains 'manifest.json') {
            Copy-PrivateArtifact -Pod $pod -PodDirectory $podDirectory -Artifact 'manifest.json' -LocalDirectory $clientDirectory -RequestId $requestId
            $manifestCopied = $true
            break
        }
        $state = Invoke-ControlPlaneFunction 'live_state' @{ token = $sessionToken }
        $current = @($state.agents | Where-Object { $_.clientName -eq $clientName })[0]
        if ($null -ne $current -and $current.dataExport.status -eq 'failed') {
            throw "$clientName export failed: $($current.dataExport.message)"
        }
        Start-Sleep -Seconds 5
    }
    if (-not $manifestCopied) { throw "$clientName export timed out." }

    $manifestPath = Join-Path $clientDirectory 'manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $parts = @(Get-ChildItem -LiteralPath $clientDirectory -Filter '*.part' | Sort-Object Name)
    if ($parts.Count -ne [int]$manifest.chunkCount) { throw "$clientName chunk count mismatch." }
    $backupPath = Join-Path $OutputDirectory "$clientKey-$Database.bak"
    $destination = [IO.File]::Open($backupPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        foreach ($part in $parts) {
            $source = [IO.File]::OpenRead($part.FullName)
            try { $source.CopyTo($destination) } finally { $source.Dispose() }
        }
    } finally { $destination.Dispose() }
    $backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash.ToLowerInvariant()
    if ($backupHash -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw "$clientName backup checksum mismatch." }
    if ((Get-Item -LiteralPath $backupPath).Length -ne [long]$manifest.bytes) { throw "$clientName backup length mismatch." }
    $summary += [pscustomobject]@{ clientName = $clientName; clientKey = $clientKey; database = $Database; backup = $backupPath; bytes = [long]$manifest.bytes; sha256 = $backupHash }
}

$summaryPath = Join-Path $OutputDirectory 'summary.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$summary | Format-Table -AutoSize
Write-Host "Verified live client copies: $summaryPath"

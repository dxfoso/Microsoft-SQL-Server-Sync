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
    [string[]] $OnlyClient = @(),
    [switch] $ForceFresh,
    [ValidateSet('full_backup', 'change_tracking_delta')][string] $Mode = 'full_backup',
    [Nullable[long]] $BaselineVersion = $null,
    [int] $TimeoutMinutes = 240,
    [ValidateRange(1, 5)][int] $MaxExportAttempts = 3
)

$ErrorActionPreference = 'Stop'
if ($Mode -eq 'change_tracking_delta' -and $null -eq $BaselineVersion) {
    throw 'BaselineVersion is required for change_tracking_delta.'
}
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

function Invoke-SshText {
    param([string] $Command, [switch] $RequireOutput)
    $lastExitCode = 0
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $lines = @(& ssh $SshTarget $Command)
        $lastExitCode = $LASTEXITCODE
        $hasOutput = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0
        if ($lastExitCode -eq 0 -and (-not $RequireOutput -or $hasOutput)) { return $lines }
        if ($attempt -lt 6) {
            Start-Sleep -Seconds ([Math]::Min(15, $attempt * 2))
        }
    }
    throw "SSH command failed after 6 attempts (exit $lastExitCode): $Command"
}

function Get-ReadyFrontendPod {
    $podJsonLines = @(Invoke-SshText "kubectl get pods -n $Namespace -l app.kubernetes.io/component=frontend -o json" -RequireOutput)
    $podList = ($podJsonLines -join "`n") | ConvertFrom-Json
    $readyPods = @($podList.items | Where-Object {
        $null -eq $_.metadata.deletionTimestamp -and
        $_.status.phase -eq 'Running' -and
        @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
    } | Sort-Object { [DateTime]$_.metadata.creationTimestamp } -Descending)
    if ($readyPods.Count -eq 0) { throw 'No ready frontend pod is available for private export collection.' }
    return [string]$readyPods[0].metadata.name
}

function Assert-FrontendPodStable([string] $ExpectedPod) {
    $readyPod = Get-ReadyFrontendPod
    if (-not $readyPod.Equals($ExpectedPod, [StringComparison]::Ordinal)) {
        throw "FRONTEND_POD_REPLACED: expected $ExpectedPod but current ready pod is $readyPod"
    }
}

function Reset-LocalAttemptDirectory([string] $AttemptDirectory) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedAttempt = [IO.Path]::GetFullPath($AttemptDirectory)
    $expectedParent = [IO.Path]::GetDirectoryName($resolvedAttempt).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $expectedParent.Equals($resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear export attempt outside $resolvedOutput"
    }
    if (Test-Path -LiteralPath $resolvedAttempt) {
        $attemptItem = Get-Item -LiteralPath $resolvedAttempt -Force
        if (-not $attemptItem.PSIsContainer -or ($attemptItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to clear unsafe export attempt path: $resolvedAttempt"
        }
        Remove-Item -LiteralPath $resolvedAttempt -Recurse -Force
    }
    New-Item -ItemType Directory -Path $resolvedAttempt | Out-Null
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
    $remoteHashLines = @(Invoke-SshText "sha256sum '$remoteTemp'" -RequireOutput)
    if ($remoteHashLines.Count -eq 0) { throw "Remote checksum returned no output for $Artifact" }
    $remoteHash = ([string]$remoteHashLines[0]).Split(' ')[0].Trim().ToLowerInvariant()
    $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash.ToLowerInvariant()
    if ($remoteHash -ne $localHash) { throw "Checksum mismatch while copying $Artifact" }
    Invoke-SshText "rm -f '$remoteTemp'" | Out-Null
}

function Remove-VerifiedRemoteExport {
    param([string] $Pod, [string] $RequestId, [string] $ClientKey)
    if ($RequestId -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw "Refusing to clean an invalid remote export request id: $RequestId"
    }
    if ($ClientKey -notmatch '^[A-Za-z0-9_-]{1,256}$') {
        throw "Refusing to clean an invalid remote export client key: $ClientKey"
    }
    Assert-FrontendPodStable $Pod
    $verifiedDirectory = "/app/data/client-updates/.private-exports/$RequestId/$ClientKey"
    Invoke-SshText "kubectl exec -n $Namespace '$Pod' -- rm -rf -- '$verifiedDirectory'" | Out-Null
}

$login = Invoke-ControlPlaneFunction 'auth_login' @{
    name = $AdminUsername
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
if ($OnlyClient.Count -gt 0) {
    $requestedClients = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($requestedClient in $OnlyClient) {
        if (-not [string]::IsNullOrWhiteSpace($requestedClient)) {
            [void]$requestedClients.Add($requestedClient.Trim())
        }
    }
    $clients = @($clients | Where-Object { $requestedClients.Contains([string]$_.clientName) })
    $foundClients = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($selectedClient in $clients) {
        [void]$foundClients.Add([string]$selectedClient.clientName)
    }
    $missingClients = @($requestedClients | Where-Object { -not $foundClients.Contains($_) })
    if ($missingClients.Count -gt 0) {
        throw "Requested client is not online and SQL-connected for ${Database}: $($missingClients -join ', ')"
    }
}
if ($clients.Count -eq 0) { throw "No online SQL-connected clients selected $Database." }

$summary = @()
$seenClientNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($client in $clients) {
    $clientName = [string]$client.clientName
    if (-not $seenClientNames.Add($clientName)) {
        Write-Host "Skipping duplicate control-plane metadata row for $clientName."
        continue
    }
    $clientKey = Get-ClientKey $clientName
    $completedClient = $false
    for ($attempt = 1; $attempt -le $MaxExportAttempts -and -not $completedClient; $attempt++) {
        $clientDirectory = Join-Path $OutputDirectory "$clientKey-attempt-$attempt"
        Reset-LocalAttemptDirectory $clientDirectory
        $pod = Get-ReadyFrontendPod
        $requestId = ''
        if ($attempt -eq 1) {
            $existingExport = $client.dataExport
            $existingRequestId = if ($null -eq $existingExport) { '' } else { [string]$existingExport.requestId }
            $existingStatus = if ($null -eq $existingExport) { '' } else { ([string]$existingExport.status).Trim().ToLowerInvariant() }
            $validExistingRequest = $existingRequestId -match '^[A-Za-z0-9._-]{1,64}$'
            $canResume = -not $ForceFresh -and $validExistingRequest -and (
                ($existingExport.pending -eq $true -and @('requested', 'running') -contains $existingStatus) -or
                $existingStatus -eq 'completed'
            )
            if ($canResume) {
                $requestId = $existingRequestId
                if ($existingStatus -eq 'completed') {
                    Write-Host "Reusing completed read-only export $requestId for $clientName."
                } else {
                    Write-Host "Resuming pending read-only export $requestId ($existingStatus) for $clientName."
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($requestId)) {
            $request = Invoke-ControlPlaneFunction 'agent_data_export_request' @{
                clientName = $clientName
                database = $Database
                uploadUrl = "$($BaseUrl.TrimEnd('/'))/private-export"
                uploadToken = $UploadToken
                mode = $Mode
                baselineVersion = $BaselineVersion
                token = $sessionToken
            }
            $requestId = [string]$request.dataExport.requestId
            Write-Host "Requested read-only export attempt $attempt of $MaxExportAttempts ($requestId) for $clientName on $pod."
        }
        if ($requestId -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw "Invalid request id for $clientName" }
        $copied = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
        $manifestCopied = $false
        $podDirectory = "/app/data/client-updates/.private-exports/$requestId/$clientKey"
        try {
            while ([DateTime]::UtcNow -lt $deadline -and -not $manifestCopied) {
                Assert-FrontendPodStable $pod
                $available = Invoke-SshText "kubectl exec -n $Namespace '$pod' -- sh -c 'if [ -d `"$podDirectory`" ]; then ls -1 `"$podDirectory`" | sort; fi'"
                $availableParts = @($available | Where-Object { $_ -match '^\d{8}\.part$' })
                if ($copied.Count -eq 0 -and
                    $availableParts.Count -gt 0 -and
                    $availableParts[0] -ne '00000000.part') {
                    throw "FRONTEND_EXPORT_MISSING: export $requestId starts at $($availableParts[0]) on $pod instead of part zero"
                }
                foreach ($artifact in $availableParts) {
                    if ($copied.Add($artifact)) {
                        Assert-FrontendPodStable $pod
                        Copy-PrivateArtifact -Pod $pod -PodDirectory $podDirectory -Artifact $artifact -LocalDirectory $clientDirectory -RequestId $requestId
                    }
                }
                if ($available -contains 'manifest.json') {
                    Assert-FrontendPodStable $pod
                    Copy-PrivateArtifact -Pod $pod -PodDirectory $podDirectory -Artifact 'manifest.json' -LocalDirectory $clientDirectory -RequestId $requestId
                    $manifestCopied = $true
                    break
                }
                $state = Invoke-ControlPlaneFunction 'live_state' @{ token = $sessionToken }
                $current = @($state.agents | Where-Object { $_.clientName -eq $clientName })[0]
                if ($null -ne $current -and $current.dataExport.status -eq 'failed') {
                    throw "$clientName export failed: $($current.dataExport.message)"
                }
                if ($null -ne $current -and
                    $current.dataExport.status -eq 'completed' -and
                    @($available).Count -eq 0) {
                    throw "FRONTEND_EXPORT_MISSING: completed export $requestId is not present on $pod"
                }
                Start-Sleep -Seconds 30
            }
            if (-not $manifestCopied) { throw "$clientName export timed out." }

            $manifestPath = Join-Path $clientDirectory 'manifest.json'
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
            $parts = @(Get-ChildItem -LiteralPath $clientDirectory -Filter '*.part' | Sort-Object Name)
            if ($parts.Count -ne [int]$manifest.chunkCount) {
                throw "FRONTEND_EXPORT_MISSING: $clientName export has $($parts.Count) of $($manifest.chunkCount) required chunks on $pod"
            }
            $format = [string]$manifest.format
            if ($Mode -eq 'change_tracking_delta' -and $format -ne 'sql-server-change-tracking-delta-v1-gzip') {
                throw "$clientName delta export returned unexpected format $format."
            }
            if ($Mode -eq 'full_backup' -and $format -ne 'sql-server-copy-only-backup') {
                throw "$clientName backup export returned unexpected format $format."
            }
            $suffix = if ($Mode -eq 'change_tracking_delta') { '.delta.json.gz' } else { '.bak' }
            $artifactPath = Join-Path $OutputDirectory "$clientKey-$Database$suffix"
            $destination = [IO.File]::Open($artifactPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                foreach ($part in $parts) {
                    $source = [IO.File]::OpenRead($part.FullName)
                    try { $source.CopyTo($destination) } finally { $source.Dispose() }
                }
            } finally { $destination.Dispose() }
            $artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
            if ($artifactHash -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw "$clientName export checksum mismatch." }
            if ((Get-Item -LiteralPath $artifactPath).Length -ne [long]$manifest.bytes) { throw "$clientName export length mismatch." }
            $summaryEntry = [ordered]@{ clientName = $clientName; clientKey = $clientKey; database = $Database; artifact = $artifactPath; format = $format; bytes = [long]$manifest.bytes; sha256 = $artifactHash }
            if ($Mode -eq 'full_backup') { $summaryEntry.backup = $artifactPath }
            if ($Mode -eq 'change_tracking_delta') {
                $summaryEntry.baselineVersion = [long]$manifest.baselineVersion
                $summaryEntry.upperVersion = [long]$manifest.upperVersion
                $summaryEntry.changeCount = [long]$manifest.changeCount
            }
            $summary += [pscustomobject]$summaryEntry
            Remove-VerifiedRemoteExport -Pod $pod -RequestId $requestId -ClientKey $clientKey
            $completedClient = $true
        } catch {
            $failure = $_.Exception.Message
            $podWasReplaced = $failure.StartsWith('FRONTEND_POD_REPLACED:') -or $failure.StartsWith('FRONTEND_EXPORT_MISSING:')
            if (-not $podWasReplaced) {
                try {
                    $podWasReplaced = -not (Get-ReadyFrontendPod).Equals($pod, [StringComparison]::Ordinal)
                } catch {
                    $podWasReplaced = $true
                }
            }
            if (-not $podWasReplaced -or $attempt -ge $MaxExportAttempts) { throw }
            Write-Warning "Frontend pod changed during $clientName export attempt $attempt; the incomplete local attempt will be discarded and a fresh read-only export requested. $failure"
            Reset-LocalAttemptDirectory $clientDirectory
            Start-Sleep -Seconds 15
        }
    }
    if (-not $completedClient) { throw "$clientName export did not complete after $MaxExportAttempts attempts." }
}

$summaryPath = Join-Path $OutputDirectory 'summary.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$summary | Format-Table -AutoSize
Write-Host "Verified live client copies: $summaryPath"

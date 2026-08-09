param(
    [string] $Commit = '',
    [string] $RegistryRoot = 'registry.cloud.divclouds.com/microsoft-sql-server-sync',
    [string] $SshAlias = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = (& git -C $repoRoot rev-parse HEAD).Trim()
}
if ($Commit -notmatch '^[0-9a-f]{40}$') {
    throw 'Commit must be an exact 40-character lowercase Git SHA.'
}

$backendImage = "$RegistryRoot/backend:$Commit"
$frontendImage = "$RegistryRoot/frontend:$Commit"

foreach ($image in @($backendImage, $frontendImage)) {
    & docker manifest inspect $image *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Immutable production image is unavailable: $image"
    }
}

function Invoke-RemoteKubectl {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    & ssh $SshAlias kubectl @Arguments -n $Namespace
    if ($LASTEXITCODE -ne 0) {
        throw "Remote kubectl failed: kubectl $($Arguments -join ' ') -n $Namespace"
    }
}

# Deployment names and container names intentionally differ. Keep both mappings
# explicit so a release cannot assume that they are interchangeable.
Invoke-RemoteKubectl @('set', 'image', 'deployment/sql-sync-back', "backend=$backendImage")
Invoke-RemoteKubectl @('set', 'image', 'deployment/sql-sync-front', "frontend=$frontendImage")
Invoke-RemoteKubectl @('rollout', 'status', 'deployment/sql-sync-back', '--timeout=300s')
Invoke-RemoteKubectl @('rollout', 'status', 'deployment/sql-sync-front', '--timeout=300s')

$stableObservations = 0
$lastHealthSummary = 'no response'
for ($attempt = 1; $attempt -le 24; $attempt += 1) {
    try {
        $health = Invoke-RestMethod -Uri 'https://sync.velvet-leaf.com/admin/health' -TimeoutSec 30
        $liveCommit = [string]$health.build.git_commit
        $lastHealthSummary = "ready=$($health.ready), compile_errors=$($health.compile_errors), commit=$liveCommit"
        if ($health.ready -and [int]$health.compile_errors -eq 0 -and $liveCommit -eq $Commit) {
            $stableObservations += 1
            if ($stableObservations -ge 2) {
                break
            }
        } else {
            $stableObservations = 0
        }
    } catch {
        $stableObservations = 0
        $lastHealthSummary = $_.Exception.Message
    }

    Start-Sleep -Seconds 5
}
if ($stableObservations -lt 2) {
    throw "Production health did not converge to the exact commit and remain stable: $lastHealthSummary"
}

Write-Host "DEPLOYED_COMMIT=$Commit"
Write-Host "BACKEND_IMAGE=$backendImage"
Write-Host "FRONTEND_IMAGE=$frontendImage"

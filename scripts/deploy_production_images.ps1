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

$health = Invoke-RestMethod -Uri 'https://sync.velvet-leaf.com/admin/health' -TimeoutSec 30
if (-not $health.ready -or [int]$health.compile_errors -ne 0) {
    throw 'Production health is not ready or reports compile errors.'
}
$liveCommit = [string]$health.build.git_commit
if ($liveCommit -ne $Commit) {
    throw "Production commit mismatch: expected $Commit, observed $liveCommit"
}

Write-Host "DEPLOYED_COMMIT=$Commit"
Write-Host "BACKEND_IMAGE=$backendImage"
Write-Host "FRONTEND_IMAGE=$frontendImage"

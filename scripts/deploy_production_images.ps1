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

function Assert-RegistryManifestAvailable {
    param(
        [Parameter(Mandatory = $true)][string] $Image,
        [ValidateRange(1, 5)][int] $Attempts = 3
    )
    $lastExitCode = 0
    for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
        & docker manifest inspect $Image *> $null
        $lastExitCode = $LASTEXITCODE
        if ($lastExitCode -eq 0) {
            return
        }
        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
        }
    }
    throw "Immutable production image is unavailable after $Attempts attempts: $Image (exit code $lastExitCode)"
}

foreach ($image in @($backendImage, $frontendImage)) {
    Assert-RegistryManifestAvailable -Image $image
}

function Invoke-RemoteKubectl {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [ValidateRange(1, 5)][int] $Attempts = 3
    )
    $lastExitCode = 0
    for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
        & ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4 $SshAlias kubectl @Arguments -n $Namespace
        $lastExitCode = $LASTEXITCODE
        if ($lastExitCode -eq 0) {
            return
        }
        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
        }
    }
    throw "Remote kubectl failed after $Attempts attempts: kubectl $($Arguments -join ' ') -n $Namespace (exit code $lastExitCode)"
}

# Deployment names and container names intentionally differ. Keep every main
# and init-container mapping explicit so one pod template cannot reference two
# different immutable backend releases.
Invoke-RemoteKubectl @(
    'set', 'image', 'deployment/sql-sync-back',
    "backend=$backendImage",
    "backend-data-permissions=$backendImage"
)
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

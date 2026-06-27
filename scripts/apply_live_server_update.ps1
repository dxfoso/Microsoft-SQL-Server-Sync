param(
    [string] $DeploymentEnvPath = "$PSScriptRoot\..\deployment\chart\.env",
    [string] $ChartPath = "$PSScriptRoot\..\deployment\chart",
    [string] $ValuesPath = "$PSScriptRoot\..\deployment\chart\values.yaml",
    [string] $Namespace = '',
    [string] $ReleaseName = '',
    [switch] $SkipTests,
    [switch] $SkipBuildMetadata,
    [switch] $Wait
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-NamespaceFromDeploymentEnv {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    $match = Select-String -LiteralPath $Path -Pattern '^\s*Namespace:\s*(\S+)\s*$' | Select-Object -First 1
    if (-not $match) {
        return ''
    }
    return $match.Matches[0].Groups[1].Value
}

function Invoke-CheckedNative {
    param(
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][scriptblock] $Command
    )

    Write-Host $Description
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $Description"
    }
}

if ([string]::IsNullOrWhiteSpace($Namespace)) {
    $Namespace = Get-NamespaceFromDeploymentEnv -Path $DeploymentEnvPath
}
if ([string]::IsNullOrWhiteSpace($Namespace)) {
    throw 'Namespace is required. Pass -Namespace or keep deployment/chart/.env available.'
}
if ([string]::IsNullOrWhiteSpace($ReleaseName)) {
    $ReleaseName = $Namespace
}
if (-not (Test-Path -LiteralPath $ChartPath -PathType Container)) {
    throw "Chart path not found: $ChartPath"
}
if (-not (Test-Path -LiteralPath $ValuesPath -PathType Leaf)) {
    throw "Values file not found: $ValuesPath"
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$waitArgs = @()
if ($Wait) {
    $waitArgs = @('--wait', '--timeout', '10m')
}

if (-not $SkipTests) {
    Invoke-CheckedNative -Description 'Running deployment chart tests...' -Command {
        & python -m pytest "$repoRoot\deployment\chart\tests\test_chart_contracts.py" "$repoRoot\tests\test_sync_contracts.py" "$repoRoot\tests\test_control_plane_contracts.py"
    }
}

if (-not $SkipBuildMetadata) {
    $commit = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve git commit for live server update.'
    }
    Write-Host "Applying chart from commit $commit"
}

Invoke-CheckedNative -Description "Ensuring namespace $Namespace exists..." -Command {
    & kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
}

Invoke-CheckedNative -Description "Applying Helm chart release $ReleaseName into namespace $Namespace..." -Command {
    & helm upgrade --install $ReleaseName $ChartPath --namespace $Namespace --create-namespace --values $ValuesPath @waitArgs
}

Invoke-CheckedNative -Description 'Waiting for frontend rollout...' -Command {
    & kubectl rollout status deployment/$ReleaseName-frontend -n $Namespace --timeout=10m
}

Invoke-CheckedNative -Description 'Waiting for backend rollout...' -Command {
    & kubectl rollout status deployment/$ReleaseName-backend -n $Namespace --timeout=10m
}

Invoke-CheckedNative -Description 'Checking public backend health...' -Command {
    & kubectl get ingress -n $Namespace
}

Write-Host "Live server update applied to namespace $Namespace using helm upgrade --install."

[CmdletBinding()]
param(
    [string] $CloudEnvPath = '',
    [string] $BootstrapUri = 'https://cloud.divclouds.com/call/repositories/ebbd5457-3253-46e0-b67d-5668ca1e5225/deployment-v1/bootstrap?namespaceName=velvet-sql-server-sync',
    [string] $ReleaseName = 'microsoft-sql-server-sync-velvet-sql-server-sync',
    [string] $RegistryProbeTag = '96dd9579fd3f17236aada1d6af600e5059c51994'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($CloudEnvPath)) {
    $CloudEnvPath = Join-Path $repoRoot '.cloud.env'
}
$line = Get-Content -LiteralPath $CloudEnvPath | Where-Object {
    $_ -like 'CLOUD_AUTH_TOKEN=*'
} | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($line)) { throw 'Cloud token is unavailable.' }
$cloudToken = $line.Substring('CLOUD_AUTH_TOKEN='.Length)
try {
    $bootstrap = Invoke-RestMethod -Method Get -Uri $BootstrapUri `
        -Headers @{ Authorization = "Bearer $cloudToken" } -TimeoutSec 60
}
catch { throw 'Cloud Bootstrap failed; response details suppressed.' }
if ($null -eq $bootstrap.PSObject.Properties['registry'] -and
    $null -ne $bootstrap.PSObject.Properties['value']) { $bootstrap = $bootstrap.value }
if ([string]$bootstrap.schemaVersion -ne 'cloud.deployment.bootstrap.v1') {
    throw 'Cloud Bootstrap returned an unsupported schemaVersion.'
}

$namespace = [string]$bootstrap.kubernetes.namespaceName
$kubeconfigText = [string]$bootstrap.kubernetes.kubeconfig
$registryHost = [string]$bootstrap.registry.host
$registryUser = [string]$bootstrap.registry.username
$registryPassword = [string]$bootstrap.registry.password
$registryRoot = [string]$bootstrap.registry.imageRepository
$pullSecretName = [string]$bootstrap.registry.imagePullSecretName
$targetNodeName = [string]$bootstrap.target.targetNodeName
if ($namespace -ne 'velvet-sql-server-sync' -or $pullSecretName -ne 'regcred' -or
    @($kubeconfigText, $registryHost, $registryUser, $registryPassword,
      $registryRoot, $targetNodeName | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_)
      }).Count -ne 0) {
    throw 'Cloud Bootstrap returned an incomplete or unexpected access contract.'
}
if ($kubeconfigText -notmatch '^\s*apiVersion:') {
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kubeconfigText))
    if ($decoded -notmatch '^\s*apiVersion:') { throw 'Unsupported kubeconfig format.' }
    $kubeconfigText = $decoded
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = [IO.Path]::GetFullPath((Join-Path $tempBase (
    'sql-sync-cloud-deploy-' + [Guid]::NewGuid().ToString('N'))))
if (-not $tempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary deployment path validation failed.'
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$kubeconfigPath = Join-Path $tempRoot 'kubeconfig.yaml'
$dockerConfig = Join-Path $tempRoot 'docker'
New-Item -ItemType Directory -Path $dockerConfig | Out-Null
[IO.File]::WriteAllText($kubeconfigPath, $kubeconfigText,
    (New-Object Text.UTF8Encoding($false)))

function Test-ProductionState {
    param([string] $Commit)
    $lines = & kubectl --kubeconfig $kubeconfigPath get deployments `
        sql-sync-back sql-sync-front -n $namespace -o json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect deployed workloads.' }
    $deployments = @((($lines -join "`n") | ConvertFrom-Json).items)
    $expected = @{
        'sql-sync-back' = "$registryRoot/backend:$Commit"
        'sql-sync-front' = "$registryRoot/frontend:$Commit"
    }
    foreach ($deployment in $deployments) {
        $name = [string]$deployment.metadata.name
        if ([string]$deployment.spec.template.spec.containers[0].image -ne $expected[$name] -or
            [int]$deployment.status.readyReplicas -lt 1) {
            throw "Deployment $name is not Ready on its exact immutable image."
        }
    }
    $podLines = & kubectl --kubeconfig $kubeconfigPath get pods -n $namespace `
        -l 'app.kubernetes.io/component in (backend,frontend)' -o json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect workload node placement.' }
    $pods = @((($podLines -join "`n") | ConvertFrom-Json).items | Where-Object {
        [string]$_.status.phase -eq 'Running'
    })
    if ($pods.Count -lt 2 -or @($pods | Where-Object {
        [string]$_.spec.nodeName -ne $targetNodeName
    }).Count -ne 0) { throw 'Ready workloads are not all on the Bootstrap target node.' }

    $health = Invoke-RestMethod -Uri 'https://sync.velvet-leaf.com/admin/health' -TimeoutSec 30
    if (-not [bool]$health.ready -or -not [bool]$health.db_available -or
        [int]$health.compile_errors -ne 0 -or
        [string]$health.build.git_commit -ne $Commit) {
        throw 'Public application health does not match the deployed immutable commit.'
    }
    $ui = Invoke-WebRequest -UseBasicParsing -Uri 'https://sync.velvet-leaf.com/' -TimeoutSec 30
    if ([int]$ui.StatusCode -ne 200) { throw 'Public ingress returned a non-200 response.' }
}

try {
    $loginOutput = $registryPassword | & docker --config $dockerConfig login `
        $registryHost --username $registryUser --password-stdin 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Registry login failed; details suppressed.' }
    $basic = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("${registryUser}:${registryPassword}"))
    try {
        $v2 = Invoke-WebRequest -UseBasicParsing -Uri "https://$registryHost/v2/" `
            -Headers @{ Authorization = "Basic $basic" } -TimeoutSec 30
    }
    catch { throw 'Authenticated registry /v2/ verification failed.' }
    if ([int]$v2.StatusCode -ne 200) { throw 'Registry /v2/ did not return HTTP 200.' }

    $env:DOCKER_CONFIG = $dockerConfig
    & (Join-Path $PSScriptRoot 'build_production_images.ps1') `
        -RegistryRoot $registryRoot -RegistryAccessProbeTag $RegistryProbeTag
    if ($LASTEXITCODE -ne 0) { throw 'Immutable production image build/push failed.' }
    $commit = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'Unable to resolve deployment commit.' }

    foreach ($resource in @('pvc/sql-sync-postgres-backups',
            'cronjob/sql-sync-postgres-backup')) {
        & kubectl --kubeconfig $kubeconfigPath annotate $resource -n $namespace `
            "meta.helm.sh/release-name=$ReleaseName" `
            "meta.helm.sh/release-namespace=$namespace" --overwrite | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to adopt $resource into Helm." }
    }
    & helm lint (Join-Path $repoRoot 'deployment\chart') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Helm lint failed.' }
    & helm upgrade --install $ReleaseName (Join-Path $repoRoot 'deployment\chart') `
        --namespace $namespace --kubeconfig $kubeconfigPath --reuse-values `
        --set-string "backend.image=$registryRoot/backend:$commit" `
        --set-string "frontend.image=$registryRoot/frontend:$commit" `
        --wait --timeout 10m
    if ($LASTEXITCODE -ne 0) { throw 'Helm deployment failed.' }

    Test-ProductionState -Commit $commit
    Start-Sleep -Seconds 60
    Test-ProductionState -Commit $commit
    [pscustomobject]@{
        deployed = $true
        commit = $commit
        helmRelease = $ReleaseName
        exactImages = $true
        targetNode = $true
        registryAuthenticated = $true
        stableChecks = 2
    } | ConvertTo-Json -Compress
}
finally {
    Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue
    Remove-Variable cloudToken, registryPassword, kubeconfigText, basic -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

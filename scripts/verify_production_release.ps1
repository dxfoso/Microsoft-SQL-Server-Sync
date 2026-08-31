[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $Commit,
    [ValidateRange(0, 60)][int] $StabilitySeconds = 20,
    [string] $SshAlias = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-CurlText {
    param([Parameter(Mandatory = $true)][string] $Uri)
    $text = & curl.exe --fail --silent --show-error $Uri
    if ($LASTEXITCODE -ne 0) {
        throw "Public verification failed for $Uri."
    }
    return ($text -join "`n")
}

function Test-ReleaseOnce {
    $health = (Invoke-CurlText 'https://sync.velvet-leaf.com/admin/health') | ConvertFrom-Json
    $manifest = (Invoke-CurlText 'https://sync.velvet-leaf.com/client/latest.json') | ConvertFrom-Json
    $uiStatus = (& curl.exe --fail --silent --show-error --output NUL --write-out '%{http_code}' 'https://sync.velvet-leaf.com/').Trim()
    if ($LASTEXITCODE -ne 0 -or $uiStatus -ne '200') {
        throw "Public web verification failed with HTTP status $uiStatus."
    }

    $rawDeployments = & ssh $SshAlias kubectl get deployment sql-sync-back sql-sync-front -n $Namespace -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read production deployments in namespace $Namespace."
    }
    $deployments = (($rawDeployments -join "`n") | ConvertFrom-Json).items
    $expectedImages = @{
        'sql-sync-back' = "registry.cloud.divclouds.com/microsoft-sql-server-sync/backend:$Commit"
        'sql-sync-front' = "registry.cloud.divclouds.com/microsoft-sql-server-sync/frontend:$Commit"
    }
    foreach ($deployment in $deployments) {
        $name = [string]$deployment.metadata.name
        $image = [string]$deployment.spec.template.spec.containers[0].image
        if (-not $expectedImages.ContainsKey($name) -or $image -ne $expectedImages[$name]) {
            throw "Unexpected production image for $name`: $image"
        }
        if ([int]$deployment.status.availableReplicas -lt 1 -or [int]$deployment.status.readyReplicas -lt 1) {
            throw "Production deployment $name is not ready."
        }
    }
    if ($health.ready -ne $true -or [int]$health.compile_errors -ne 0 -or [string]$health.build.git_commit -ne $Commit) {
        throw "Production health does not match ready commit $Commit with zero compile errors."
    }
    return [pscustomobject]@{
        ready = $health.ready
        compileErrors = [int]$health.compile_errors
        commit = [string]$health.build.git_commit
        uiStatus = [int]$uiStatus
        clientVersion = [string]$manifest.version
    }
}

$first = Test-ReleaseOnce
if ($StabilitySeconds -gt 0) {
    Start-Sleep -Seconds $StabilitySeconds
}
$second = Test-ReleaseOnce
[pscustomobject]@{ first = $first; stable = $second } | ConvertTo-Json -Compress

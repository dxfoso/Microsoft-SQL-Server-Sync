[CmdletBinding()]
param(
    [string] $CloudEnvPath = '',
    [string] $BootstrapUri = 'https://cloud.divclouds.com/call/repositories/ebbd5457-3253-46e0-b67d-5668ca1e5225/deployment-v1/bootstrap?namespaceName=velvet-sql-server-sync',
    [string] $ExpectedNamespace = 'velvet-sql-server-sync',
    [string] $ExpectedPullSecretName = 'regcred',
    [string] $VerificationTag = '96dd9579fd3f17236aada1d6af600e5059c51994'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($CloudEnvPath)) {
    $CloudEnvPath = Join-Path $PSScriptRoot '..\.cloud.env'
}
$CloudEnvPath = [IO.Path]::GetFullPath($CloudEnvPath)

$envLine = Get-Content -LiteralPath $CloudEnvPath | Where-Object {
    $_ -like 'CLOUD_AUTH_TOKEN=*'
} | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($envLine)) { throw 'Cloud token is unavailable.' }
$cloudToken = $envLine.Substring('CLOUD_AUTH_TOKEN='.Length)

try {
    $bootstrap = Invoke-RestMethod -Method Get -Uri $BootstrapUri `
        -Headers @{ Authorization = "Bearer $cloudToken" } -TimeoutSec 60
}
catch {
    throw 'Cloud Bootstrap failed; response details suppressed.'
}
if ($null -eq $bootstrap.PSObject.Properties['registry'] -and
    $null -ne $bootstrap.PSObject.Properties['value']) {
    $bootstrap = $bootstrap.value
}

$registryHost = [string]$bootstrap.registry.host
$registryUser = [string]$bootstrap.registry.username
$registryPassword = [string]$bootstrap.registry.password
$imageRepository = [string]$bootstrap.registry.imageRepository
$pullSecretName = [string]$bootstrap.registry.imagePullSecretName
$namespace = ''
if ($null -ne $bootstrap.kubernetes.PSObject.Properties['namespace']) {
    $namespace = [string]$bootstrap.kubernetes.namespace
}
if ([string]::IsNullOrWhiteSpace($namespace) -and
    $null -ne $bootstrap.kubernetes.PSObject.Properties['namespaceName']) {
    $namespace = [string]$bootstrap.kubernetes.namespaceName
}
$kubeconfigText = [string]$bootstrap.kubernetes.kubeconfig
$required = @($registryHost, $registryUser, $registryPassword, $imageRepository,
    $pullSecretName, $namespace, $kubeconfigText)
if (@($required | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) {
    throw 'Cloud Bootstrap omitted required access fields.'
}
if ($namespace -ne $ExpectedNamespace -or $pullSecretName -ne $ExpectedPullSecretName) {
    throw 'Cloud Bootstrap returned an unexpected namespace or pull Secret.'
}
if ($kubeconfigText -notmatch '^\s*apiVersion:') {
    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kubeconfigText))
        if ($decoded -notmatch '^\s*apiVersion:') { throw 'invalid kubeconfig' }
        $kubeconfigText = $decoded
    }
    catch { throw 'Cloud Bootstrap kubeconfig format is unsupported.' }
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = [IO.Path]::GetFullPath((Join-Path $tempBase (
    'sql-sync-cloud-' + [Guid]::NewGuid().ToString('N'))))
if (-not $tempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary path validation failed.'
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$kubeconfigPath = Join-Path $tempRoot 'kubeconfig.yaml'
[IO.File]::WriteAllText($kubeconfigPath, $kubeconfigText,
    (New-Object Text.UTF8Encoding($false)))

try {
    $registryAuthenticated = $false
    foreach ($attempt in 1..2) {
        $dockerConfig = Join-Path $tempRoot "docker-config-$attempt"
        New-Item -ItemType Directory -Path $dockerConfig | Out-Null
        $loginOutput = $registryPassword | & docker --config $dockerConfig login `
            $registryHost --username $registryUser --password-stdin 2>&1
        if ($LASTEXITCODE -eq 0) {
            $registryAuthenticated = $true
            break
        }
    }
    if (-not $registryAuthenticated) {
        throw 'Parsed registry credential failed two fresh-config login attempts.'
    }

    $basic = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("${registryUser}:${registryPassword}"))
    try {
        $v2 = Invoke-WebRequest -UseBasicParsing -Uri "https://$registryHost/v2/" `
            -Headers @{ Authorization = "Basic $basic" } -TimeoutSec 30
    }
    catch { throw 'Authenticated registry /v2/ verification failed.' }
    if ([int]$v2.StatusCode -ne 200) {
        throw 'Authenticated registry /v2/ did not return HTTP 200.'
    }

    $secretLines = & kubectl --kubeconfig $kubeconfigPath get secret `
        $pullSecretName -n $namespace -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the current pull Secret through Bootstrap kubeconfig.'
    }
    $secret = (($secretLines -join "`n") | ConvertFrom-Json)
    $oldConfigText = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String([string]$secret.data.'.dockerconfigjson'))
    $oldConfig = $oldConfigText | ConvertFrom-Json
    $oldAuthProperty = $oldConfig.auths.PSObject.Properties[$registryHost]
    $oldUser = ''
    $oldPassword = ''
    if ($null -ne $oldAuthProperty) {
        $oldUser = [string]$oldAuthProperty.Value.username
        $oldPassword = [string]$oldAuthProperty.Value.password
        if ([string]::IsNullOrWhiteSpace($oldUser) -and
            -not [string]::IsNullOrWhiteSpace([string]$oldAuthProperty.Value.auth)) {
            $pair = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
                [string]$oldAuthProperty.Value.auth)) -split ':', 2
            $oldUser = $pair[0]
            $oldPassword = $pair[1]
        }
    }
    $credentialChanged = $oldUser -cne $registryUser -or
        $oldPassword -cne $registryPassword

    $authValue = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("${registryUser}:${registryPassword}"))
    $dockerJson = @{ auths = @{ $registryHost = @{
        username = $registryUser
        password = $registryPassword
        auth = $authValue
    } } } | ConvertTo-Json -Depth 6 -Compress
    $manifest = @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{ name = $pullSecretName; namespace = $namespace }
        type = 'kubernetes.io/dockerconfigjson'
        data = @{ '.dockerconfigjson' = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($dockerJson)) }
    } | ConvertTo-Json -Depth 8 -Compress
    $applyOutput = $manifest | & kubectl --kubeconfig $kubeconfigPath apply `
        -n $namespace -f - 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Unable to update the registry pull Secret.' }

    $verificationPod = 'sql-sync-registry-pull-verification'
    $verificationImage = "$($imageRepository.TrimEnd('/'))/frontend:$VerificationTag"
    $podManifest = @{
        apiVersion = 'v1'
        kind = 'Pod'
        metadata = @{ name = $verificationPod; namespace = $namespace }
        spec = @{
            restartPolicy = 'Never'
            imagePullSecrets = @(@{ name = $pullSecretName })
            containers = @(@{
                name = 'verify'
                image = $verificationImage
                imagePullPolicy = 'Always'
                command = @('/bin/sh', '-c', 'exit 0')
            })
        }
    } | ConvertTo-Json -Depth 10 -Compress
    & kubectl --kubeconfig $kubeconfigPath delete pod $verificationPod `
        -n $namespace --ignore-not-found --wait=true | Out-Null
    $podManifest | & kubectl --kubeconfig $kubeconfigPath apply -n $namespace -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create registry pull verification Pod.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    do {
        $podLines = & kubectl --kubeconfig $kubeconfigPath get pod `
            $verificationPod -n $namespace -o json
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect registry pull verification Pod.' }
        $pod = (($podLines -join "`n") | ConvertFrom-Json)
        $phase = [string]$pod.status.phase
        if ($phase -in @('Succeeded', 'Failed')) { break }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($phase -ne 'Succeeded') { throw 'Registry pull verification did not succeed.' }
    & kubectl --kubeconfig $kubeconfigPath delete pod $verificationPod `
        -n $namespace --wait=true | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to remove successful pull verification Pod.' }

    [pscustomobject]@{
        bootstrapFetchedOnce = $true
        dockerLogin = $true
        registryV2Http200 = $true
        pullSecretUpdated = $true
        credentialDifferentFromExposedSecret = $credentialChanged
        immutableImagePulled = $true
        namespace = $namespace
        pullSecretName = $pullSecretName
    } | ConvertTo-Json -Compress
}
finally {
    Remove-Variable cloudToken, registryPassword, kubeconfigText, basic,
        authValue, dockerJson, manifest, oldPassword -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $Commit,
    [string] $RegistryHost = 'registry.cloud.divclouds.com',
    [string] $SshAlias = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $PullSecretName = 'regcred'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$dockerConfig = Join-Path $temporaryRoot ("sql-sync-registry-deploy-{0}" -f ([guid]::NewGuid().ToString('N')))
$previousDockerConfig = [Environment]::GetEnvironmentVariable('DOCKER_CONFIG', 'Process')

function Read-RequiredProperty([object] $Object, [string] $Name, [string] $Description) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "$Description is unavailable."
    }
    return [string]$property.Value
}

try {
    $secretLines = @(& ssh $SshAlias "kubectl get secret $PullSecretName -n $Namespace -o json")
    if ($LASTEXITCODE -ne 0 -or $secretLines.Count -eq 0) {
        throw 'Unable to read the namespace image pull Secret.'
    }
    try {
        $secret = ($secretLines -join "`n") | ConvertFrom-Json
        $encodedConfig = Read-RequiredProperty $secret.data '.dockerconfigjson' 'Docker config key'
        $registryConfig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedConfig)) | ConvertFrom-Json
    }
    catch {
        throw 'Unable to parse the namespace image pull Secret; credential details suppressed.'
    }
    $authProperty = $registryConfig.auths.PSObject.Properties |
        Where-Object {
            ([string]$_.Name).TrimEnd('/').EndsWith($RegistryHost, [StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object -First 1
    if ($null -eq $authProperty) {
        throw "The namespace pull Secret has no entry for $RegistryHost."
    }
    $entry = $authProperty.Value
    $username = ''
    $password = ''
    if ($null -ne $entry.PSObject.Properties['username']) { $username = [string]$entry.username }
    if ($null -ne $entry.PSObject.Properties['password']) { $password = [string]$entry.password }
    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        $encodedAuth = Read-RequiredProperty $entry 'auth' 'Registry auth field'
        $decodedAuth = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedAuth))
        $separator = $decodedAuth.IndexOf(':')
        if ($separator -le 0) { throw 'The namespace pull Secret registry auth field is invalid.' }
        $username = $decodedAuth.Substring(0, $separator)
        $password = $decodedAuth.Substring($separator + 1)
    }
    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        throw 'The namespace pull Secret registry credential is incomplete.'
    }

    New-Item -ItemType Directory -Path $dockerConfig -Force | Out-Null
    $env:DOCKER_CONFIG = $dockerConfig
    $password | & docker login $RegistryHost --username $username --password-stdin
    if ($LASTEXITCODE -ne 0) {
        throw 'Registry authentication failed with the exact namespace pull Secret credential.'
    }
    & (Join-Path $PSScriptRoot 'deploy_production_images.ps1') `
        -Commit $Commit `
        -SshAlias $SshAlias `
        -Namespace $Namespace
    if ($LASTEXITCODE -ne 0) {
        throw "Production deployment failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Variable password, username, encodedAuth, decodedAuth, encodedConfig, registryConfig, secret -ErrorAction SilentlyContinue
    if ($null -eq $previousDockerConfig) {
        [Environment]::SetEnvironmentVariable('DOCKER_CONFIG', $null, 'Process')
    } else {
        $env:DOCKER_CONFIG = $previousDockerConfig
    }
    $resolvedDockerConfig = [IO.Path]::GetFullPath($dockerConfig)
    if ($resolvedDockerConfig.StartsWith("$temporaryRoot\sql-sync-registry-deploy-", [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedDockerConfig)) {
        Remove-Item -LiteralPath $resolvedDockerConfig -Recurse -Force
    }
}

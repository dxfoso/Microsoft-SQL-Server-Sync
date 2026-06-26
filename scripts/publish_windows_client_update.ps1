param(
    [string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call',
    [string] $PublicBaseUrl = 'https://sync.velvet-leaf.com/client',
    [string] $OutputDir = "$PSScriptRoot\..\artifacts\client-updates",
    [string] $DeploymentEnvPath = "$PSScriptRoot\..\deployment\chart\.env",
    [string] $Namespace = '',
    [string] $SshTarget = '',
    [string] $RemoteUpdatesDir = '/app/data/client-updates',
    [string] $FlutterVersion = '',
    [string] $FlutterCacheRoot = '',
    [switch] $RequireFlutterVersion,
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$ProjectPath = Join-Path -Path $RepoRoot -ChildPath 'sync_windows_agent'
$PortableName = 'sync_windows_agent-windows-portable'
$PortableZip = Join-Path -Path $RepoRoot -ChildPath "$PortableName.zip"
$UpdaterScript = Join-Path -Path $RepoRoot -ChildPath 'update.ps1'

function Get-PubspecVersion {
    $pubspecPath = Join-Path -Path $ProjectPath -ChildPath 'pubspec.yaml'
    $match = Select-String -LiteralPath $pubspecPath -Pattern '^\s*version:\s*(\S+)\s*$' | Select-Object -First 1
    if (-not $match) {
        throw "Could not read version from $pubspecPath"
    }
    return $match.Matches[0].Groups[1].Value
}

function Get-GitCommit {
    Push-Location $RepoRoot
    try {
        return (& git rev-parse --short=12 HEAD).Trim()
    }
    finally {
        Pop-Location
    }
}

function Get-NamespaceFromDeploymentEnv {
    if (-not (Test-Path -LiteralPath $DeploymentEnvPath -PathType Leaf)) {
        return ''
    }
    $match = Select-String -LiteralPath $DeploymentEnvPath -Pattern '^\s*Namespace:\s*(\S+)\s*$' | Select-Object -First 1
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

if (-not (Test-Path -LiteralPath $UpdaterScript -PathType Leaf)) {
    throw "Missing updater script: $UpdaterScript"
}

if ([string]::IsNullOrWhiteSpace($Namespace)) {
    $Namespace = Get-NamespaceFromDeploymentEnv
}

if (-not $SkipBuild) {
    $buildArgs = @(
        '-BackendBaseUrl', $BackendBaseUrl
    )
    if (-not [string]::IsNullOrWhiteSpace($FlutterVersion)) {
        $buildArgs += @('-FlutterVersion', $FlutterVersion)
    }
    if (-not [string]::IsNullOrWhiteSpace($FlutterCacheRoot)) {
        $buildArgs += @('-FlutterCacheRoot', $FlutterCacheRoot)
    }
    if ($RequireFlutterVersion) {
        $buildArgs += '-RequireFlutterVersion'
    }
    Write-Host 'Building Windows portable client...'
    & (Join-Path -Path $RepoRoot -ChildPath 'build_portable.ps1') @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: Building Windows portable client..."
    }
}

if (-not (Test-Path -LiteralPath $PortableZip -PathType Leaf)) {
    throw "Missing portable ZIP: $PortableZip"
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

$version = Get-PubspecVersion
$commit = Get-GitCommit
$releaseDate = [DateTime]::UtcNow.ToString('o')
$safeVersion = $version -replace '[^A-Za-z0-9._-]', '-'
$zipName = "sync_windows_agent-$safeVersion-$commit.zip"
$versionedZip = Join-Path -Path $OutputDir -ChildPath $zipName
$latestZip = Join-Path -Path $OutputDir -ChildPath 'sync_windows_agent_latest.zip'
$latestManifest = Join-Path -Path $OutputDir -ChildPath 'latest.json'
$publishedUpdater = Join-Path -Path $OutputDir -ChildPath 'update.ps1'

Copy-Item -LiteralPath $PortableZip -Destination $versionedZip -Force
Copy-Item -LiteralPath $PortableZip -Destination $latestZip -Force
Copy-Item -LiteralPath $UpdaterScript -Destination $publishedUpdater -Force

$zipHash = (Get-FileHash -LiteralPath $versionedZip -Algorithm SHA256).Hash.ToLowerInvariant()
$zipSize = (Get-Item -LiteralPath $versionedZip).Length
$publicRoot = $PublicBaseUrl.TrimEnd('/')
$manifest = [ordered]@{
    version = $version
    commit = $commit
    releaseDate = $releaseDate
    zipUrl = "$publicRoot/$zipName"
    latestZipUrl = "$publicRoot/sync_windows_agent_latest.zip"
    updateScriptUrl = "$publicRoot/update.ps1"
    sha256 = $zipHash
    sizeBytes = $zipSize
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $latestManifest -Encoding ASCII

Write-Host "Client update artifacts written to $OutputDir"
Write-Host "Manifest: $latestManifest"
Write-Host "ZIP:      $versionedZip"

if ([string]::IsNullOrWhiteSpace($SshTarget)) {
    Write-Host 'No -SshTarget supplied; skipping live upload.'
    return
}

if ([string]::IsNullOrWhiteSpace($Namespace)) {
    throw 'Namespace is required for live upload. Pass -Namespace or keep deployment/chart/.env available.'
}

$remoteStage = "/tmp/sql-sync-client-update-$([guid]::NewGuid().ToString('N'))"
Invoke-CheckedNative -Description "Creating remote staging directory on $SshTarget..." -Command {
    & ssh $SshTarget "mkdir -p '$remoteStage'"
}
try {
    Invoke-CheckedNative -Description 'Uploading staged client artifacts to SSH target...' -Command {
        & scp $latestManifest $versionedZip $latestZip $publishedUpdater "$SshTarget`:$remoteStage/"
    }

    $podOutput = & ssh $SshTarget "kubectl get pods -n '$Namespace' -l app.kubernetes.io/component=frontend -o jsonpath='{range .items[*]}{.metadata.name}{\"\n\"}{end}'"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list frontend pods in namespace $Namespace"
    }
    $pods = @($podOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pods.Count -eq 0) {
        throw "No frontend pods found in namespace $Namespace"
    }

    foreach ($pod in $pods) {
        Invoke-CheckedNative -Description "Publishing client update files to pod $pod..." -Command {
            & ssh $SshTarget "kubectl exec -n '$Namespace' '$pod' -- mkdir -p '$RemoteUpdatesDir' && kubectl cp '$remoteStage/latest.json' '$Namespace/$pod`:$RemoteUpdatesDir/latest.json' && kubectl cp '$remoteStage/$zipName' '$Namespace/$pod`:$RemoteUpdatesDir/$zipName' && kubectl cp '$remoteStage/sync_windows_agent_latest.zip' '$Namespace/$pod`:$RemoteUpdatesDir/sync_windows_agent_latest.zip' && kubectl cp '$remoteStage/update.ps1' '$Namespace/$pod`:$RemoteUpdatesDir/update.ps1'"
        }
    }

    Write-Host "Uploaded client update $version ($commit) to $($pods.Count) frontend pod(s)."
}
finally {
    & ssh $SshTarget "rm -rf '$remoteStage'" | Out-Null
}

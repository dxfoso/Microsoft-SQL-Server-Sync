param(
    [string] $RegistryRoot = 'registry.cloud.divclouds.com/microsoft-sql-server-sync',
    [string] $RegistryAccessProbeTag = '',
    [string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call',
    [string] $ClientArtifactsDir = "$PSScriptRoot\..\artifacts\client-updates",
    [switch] $SkipPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'workspace'))
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
    throw 'Unable to resolve the exact root commit for production images.'
}
$commitDate = (& git -C $repoRoot show -s --format=%cI $commit).Trim()
$commitMessage = (& git -C $repoRoot show -s --format=%s $commit).Trim()
$releaseDate = [DateTime]::UtcNow.ToString('o')
$backendImage = "$RegistryRoot/backend:$commit"
$frontendImage = "$RegistryRoot/frontend:$commit"
$contextRoot = Join-Path $workspaceRoot ("production-image-context-{0}" -f ([guid]::NewGuid().ToString('N')))
$backendContext = Join-Path $contextRoot 'backend'
$frontendContext = Join-Path $contextRoot 'frontend'

function Invoke-NativeChecked {
    param([string] $Description, [scriptblock] $Command)
    Write-Host $Description
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Invoke-NativeCheckedWithRetry {
    param(
        [string] $Description,
        [scriptblock] $Command,
        [scriptblock] $Verify,
        [ValidateRange(1, 5)][int] $Attempts = 3
    )
    $lastExitCode = 0
    for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
        Write-Host "$Description attempt $attempt of $Attempts"
        & $Command
        $lastExitCode = $LASTEXITCODE
        if ($lastExitCode -eq 0 -and $null -ne $Verify) {
            & $Verify
            $lastExitCode = $LASTEXITCODE
        }
        if ($lastExitCode -eq 0) {
            return
        }
        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
        }
    }
    throw "$Description failed after $Attempts attempts with exit code $lastExitCode."
}

function Assert-RegistryAccessBeforeBuild {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $ProbeTag
    )
    foreach ($component in @('backend', 'frontend')) {
        $probeImage = "$RepositoryRoot/${component}:$ProbeTag"
        $previousErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & docker manifest inspect $probeImage 1> $null 2> $null
            $probeExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorPreference
        }
        if ($probeExitCode -ne 0) {
            throw "Production registry access preflight failed for $probeImage. Authenticate this Windows Docker client with 'docker login $($RepositoryRoot.Split('/')[0])' before building; no production image build or deployment was attempted."
        }
    }
}

try {
    if (-not $SkipPush) {
        if ([string]::IsNullOrWhiteSpace($RegistryAccessProbeTag)) {
            throw 'RegistryAccessProbeTag must name a known existing immutable tag when push is enabled; do not assume a mutable dev/latest tag exists.'
        }
        Assert-RegistryAccessBeforeBuild -RepositoryRoot $RegistryRoot -ProbeTag $RegistryAccessProbeTag
    }
    New-Item -ItemType Directory -Force -Path $backendContext, $frontendContext | Out-Null

    # Use tracked archives instead of recursively copying the working tree.
    # This excludes Rust target/, Flutter build/, logs, and other local caches
    # while keeping the backend submodule runtime and root business logic exact.
    $backendArchive = Join-Path $contextRoot 'backend.tar'
    $businessArchive = Join-Path $contextRoot 'business.tar'
    $frontendArchive = Join-Path $contextRoot 'frontend.tar'
    Invoke-NativeChecked 'Archiving backend runtime sources...' {
        & git -C (Join-Path $repoRoot 'backend') archive --format=tar --output=$backendArchive HEAD Dockerfile .dockerignore server
    }
    Invoke-NativeChecked 'Archiving root business sources...' {
        & git -C $repoRoot archive --format=tar --output=$businessArchive $commit business
    }
    Invoke-NativeChecked 'Archiving frontend sources...' {
        & git -C $repoRoot archive --format=tar --output=$frontendArchive $commit frontend
    }
    Invoke-NativeChecked 'Extracting backend runtime context...' {
        & tar -xf $backendArchive -C $backendContext
    }
    Invoke-NativeChecked 'Extracting root business context...' {
        & tar -xf $businessArchive -C $backendContext
    }
    Invoke-NativeChecked 'Extracting frontend context...' {
        & tar -xf $frontendArchive -C $contextRoot
    }

    $artifacts = [System.IO.Path]::GetFullPath($ClientArtifactsDir)
    foreach ($required in @('latest.json', 'latest-files.json', 'update.ps1', 'sync_windows_agent_latest.zip', 'packages\latest-package')) {
        if (-not (Test-Path -LiteralPath (Join-Path $artifacts $required))) {
            throw "Missing current Windows client artifact: $required"
        }
    }
    $frontendClientDir = Join-Path $frontendContext 'client-updates'
    $frontendPackageDir = Join-Path $frontendClientDir 'packages'
    $latestClientManifest = Get-Content -LiteralPath (Join-Path $artifacts 'latest.json') -Raw | ConvertFrom-Json
    $immutableManifestUri = [System.Uri]::new([string]$latestClientManifest.filesManifestUrl)
    $immutablePackageMatch = [regex]::Match($immutableManifestUri.AbsolutePath, '/packages/([A-Za-z0-9._-]+)/files\.json$')
    if (-not $immutablePackageMatch.Success) {
        throw "Latest Windows client manifest does not reference an immutable versioned package."
    }
    $immutablePackageName = $immutablePackageMatch.Groups[1].Value
    $immutablePackageDir = Join-Path $artifacts "packages\$immutablePackageName"
    if (-not (Test-Path -LiteralPath $immutablePackageDir -PathType Container)) {
        throw "Missing immutable Windows client package: $immutablePackageName"
    }
    New-Item -ItemType Directory -Force -Path $frontendClientDir, $frontendPackageDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $artifacts 'latest.json'), (Join-Path $artifacts 'latest-files.json'), (Join-Path $artifacts 'update.ps1'), (Join-Path $artifacts 'sync_windows_agent_latest.zip') -Destination $frontendClientDir -Force
    Copy-Item -LiteralPath (Join-Path $artifacts 'packages\latest-package') -Destination $frontendPackageDir -Recurse -Force
    Copy-Item -LiteralPath $immutablePackageDir -Destination $frontendPackageDir -Recurse -Force

    Invoke-NativeChecked "Building $backendImage..." {
        & docker build --build-arg "BUILD_COMMIT_HASH=$commit" --build-arg "TRU_BUILD_GIT_SHA=$commit" -t $backendImage $backendContext
    }
    Invoke-NativeCheckedWithRetry "Building $frontendImage..." {
        & docker build --build-arg "BACKEND_BASE_URL=$BackendBaseUrl" --build-arg "BUILD_COMMIT_HASH=$commit" --build-arg "BUILD_COMMIT_DATE=$commitDate" --build-arg "BUILD_RELEASE_DATE=$releaseDate" --build-arg "TRU_BUILD_GIT_SHA=$commit" --build-arg "TRU_BUILD_COMMIT_MESSAGE=$commitMessage" --build-arg "TRU_BUILD_COMMIT_DATE=$commitDate" --build-arg "TRU_BUILD_RELEASE_DATE=$releaseDate" -t $frontendImage $frontendContext
    } { & docker image inspect $frontendImage *> $null }
    if (-not $SkipPush) {
        Invoke-NativeCheckedWithRetry "Pushing $backendImage..." { & docker push $backendImage } { & docker manifest inspect $backendImage *> $null }
        Invoke-NativeCheckedWithRetry "Pushing $frontendImage..." { & docker push $frontendImage } { & docker manifest inspect $frontendImage *> $null }
    }
    Write-Host "BACKEND_IMAGE=$backendImage"
    Write-Host "FRONTEND_IMAGE=$frontendImage"
}
finally {
    $resolvedContext = [System.IO.Path]::GetFullPath($contextRoot)
    if ($resolvedContext.StartsWith($workspaceRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedContext)) {
        Remove-Item -LiteralPath $resolvedContext -Recurse -Force -ErrorAction SilentlyContinue
    }
}

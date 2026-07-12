param(
    [string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call',
    [string] $PublicBaseUrl = 'https://sync.velvet-leaf.com/client',
    [string] $ClientUpdateBaseUrl = '',
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
        $commit = (& git rev-parse --short=12 HEAD).Trim()
        $status = (& git status --porcelain)
        if ($LASTEXITCODE -eq 0 -and @($status).Count -gt 0) {
            return "$commit-dirty"
        }
        return $commit
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

function Assert-ClientUpdateZipContents {
    param([Parameter(Mandatory = $true)][string] $ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entryNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            [void] $entryNames.Add($entry.FullName.Replace('\', '/'))
        }

        $requiredEntries = @(
            "$PortableName/sync_windows_agent.exe",
            "$PortableName/update.ps1",
            "$PortableName/portable-manifest.txt"
        )
        foreach ($requiredEntry in $requiredEntries) {
            if (-not $entryNames.Contains($requiredEntry)) {
                throw "Portable client update ZIP is missing required entry: $requiredEntry"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-SingleChildDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    $children = @(Get-ChildItem -LiteralPath $Path -Directory -Force)
    if ($children.Count -eq 1) {
        return $children[0].FullName
    }

    return $Path
}

function Get-RelativeFilePath {
    param(
        [Parameter(Mandatory = $true)][string] $RootPath,
        [Parameter(Mandatory = $true)][string] $FilePath
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    $fileFullPath = [System.IO.Path]::GetFullPath($FilePath)
    $rootPrefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fileFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Cannot compute relative file path outside root. root=$rootFullPath file=$fileFullPath"
    }

    return $fileFullPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function New-PortableFilesManifest {
    param(
        [Parameter(Mandatory = $true)][string] $PortableDir,
        [Parameter(Mandatory = $true)][string] $PublicRoot,
        [Parameter(Mandatory = $true)][string] $PackageDirName,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $Commit
    )

    $files = Get-ChildItem -LiteralPath $PortableDir -Recurse -File -Force |
        Where-Object { $_.Name -ne 'files.json' } |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = Get-RelativeFilePath -RootPath $PortableDir -FilePath $_.FullName
            [ordered]@{
                path = $relativePath
                url = "$PublicRoot/packages/$PackageDirName/$relativePath"
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                sizeBytes = $_.Length
            }
        }

    return [ordered]@{
        version = $Version
        commit = $Commit
        generatedAt = [DateTime]::UtcNow.ToString('o')
        packageType = 'files-v1'
        packageRootUrl = "$PublicRoot/packages/$PackageDirName"
        fileCount = @($files).Count
        files = @($files)
    }
}

function New-PortableZipParts {
    param(
        [Parameter(Mandatory = $true)][string] $ZipPath,
        [Parameter(Mandatory = $true)][string] $BaseZipName,
        [Parameter(Mandatory = $true)][string] $PartsDir,
        [int] $PartCount = 10
    )

    if ($PartCount -lt 1) {
        throw "PartCount must be at least 1. Actual: $PartCount"
    }

    New-Item -Path $PartsDir -ItemType Directory -Force | Out-Null

    $sourceZip = [System.IO.Path]::GetFullPath($ZipPath)
    if (-not (Test-Path -LiteralPath $sourceZip -PathType Leaf)) {
        throw "Cannot split missing portable ZIP archive: $ZipPath"
    }

    $zipSizeBytes = [int64] (Get-Item -LiteralPath $sourceZip).Length
    if ($zipSizeBytes -le 0) {
        throw "Cannot split zero-byte portable ZIP archive: $ZipPath"
    }

    Get-ChildItem -LiteralPath $PartsDir -File -Force |
        Where-Object { $_.Name -match ('^{0}\.zip\.part\d{{2}}$' -f [regex]::Escape($BaseZipName)) -or $_.Name -in @('combine.ps1', 'extract_all.ps1', 'parts-manifest.txt') } |
        Remove-Item -Force

    $basePartSize = [int64] [Math]::Floor($zipSizeBytes / [double] $PartCount)
    $remainder = [int64] ($zipSizeBytes % $PartCount)
    $bufferSize = 1024 * 1024
    $buffer = [byte[]]::new($bufferSize)
    $createdPartNames = [System.Collections.Generic.List[string]]::new()

    $inputStream = [System.IO.File]::Open($sourceZip, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $bytesConsumed = [int64] 0
    try {
        for ($index = 1; $index -le $PartCount; $index++) {
            $partSize = $basePartSize
            if ($index -le $remainder) {
                $partSize++
            }

            $partName = '{0}.zip.part{1:D2}' -f $BaseZipName, $index
            $partPath = Join-Path -Path $PartsDir -ChildPath $partName
            $outputStream = [System.IO.File]::Open($partPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $remaining = [int64] $partSize
                while ($remaining -gt 0) {
                    $readLength = [int] [Math]::Min($buffer.Length, $remaining)
                    $bytesRead = $inputStream.Read($buffer, 0, $readLength)
                    if ($bytesRead -le 0) {
                        throw "Unexpected end of ZIP archive while writing $partName."
                    }
                    $outputStream.Write($buffer, 0, $bytesRead)
                    $remaining -= $bytesRead
                }
            }
            finally {
                $outputStream.Dispose()
            }
            [void] $createdPartNames.Add($partName)
        }
        $bytesConsumed = $inputStream.Position
    }
    finally {
        $inputStream.Dispose()
    }

    if ($bytesConsumed -ne $zipSizeBytes) {
        throw "ZIP split did not consume the complete archive. Read $bytesConsumed of $zipSizeBytes bytes."
    }

    if ($createdPartNames.Count -ne $PartCount) {
        throw "Expected $PartCount ZIP parts for $BaseZipName, created $($createdPartNames.Count)."
    }

    $combineScriptPath = Join-Path -Path $PartsDir -ChildPath 'combine.ps1'
    $combineScript = @(
        'param(',
        "    [string] `$OutputZip = '$BaseZipName.zip'",
        ')',
        '',
        "`$ErrorActionPreference = 'Stop'",
        "`$root = `$PSScriptRoot",
        "if ([System.IO.Path]::IsPathRooted(`$OutputZip)) {",
        "    `$destination = `$OutputZip",
        "} else {",
        "    `$destination = Join-Path -Path `$root -ChildPath `$OutputZip",
        "}",
        "if (Test-Path -LiteralPath `$destination) { Remove-Item -LiteralPath `$destination -Force }",
        "`$parts = 1..$PartCount | ForEach-Object { Join-Path -Path `$root -ChildPath ('{0}.zip.part{1:D2}' -f '$BaseZipName', `$_) }",
        "foreach (`$part in `$parts) { if (-not (Test-Path -LiteralPath `$part -PathType Leaf)) { throw ('Missing ZIP part: {0}' -f `$part) } }",
        "`$output = [System.IO.File]::Open(`$destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)",
        'try {',
        "    foreach (`$part in `$parts) {",
        "        `$input = [System.IO.File]::Open(`$part, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)",
        '        try {',
        "            `$input.CopyTo(`$output)",
        '        } finally {',
        "            `$input.Dispose()",
        '        }',
        '    }',
        '} finally {',
        "    `$output.Dispose()",
        '}',
        "Write-Host ('Combined ZIP: {0}' -f `$destination)"
    )
    Set-Content -LiteralPath $combineScriptPath -Value $combineScript -Encoding ASCII

    $extractScriptPath = Join-Path -Path $PartsDir -ChildPath 'extract_all.ps1'
    $extractScript = @(
        'param(',
        "    [string] `$OutputDir = 'extracted'",
        ')',
        '',
        "`$ErrorActionPreference = 'Stop'",
        "`$root = `$PSScriptRoot",
        "`$archive = Join-Path -Path `$root -ChildPath '$BaseZipName.zip'",
        "if (-not (Test-Path -LiteralPath `$archive -PathType Leaf)) { & (Join-Path -Path `$root -ChildPath 'combine.ps1') -OutputZip '$BaseZipName.zip' }",
        "if ([System.IO.Path]::IsPathRooted(`$OutputDir)) {",
        "    `$destination = `$OutputDir",
        "} else {",
        "    `$destination = Join-Path -Path `$root -ChildPath `$OutputDir",
        "}",
        "if (Test-Path -LiteralPath `$destination) { Remove-Item -LiteralPath `$destination -Recurse -Force }",
        "Expand-Archive -LiteralPath `$archive -DestinationPath `$destination -Force",
        "Write-Host ('Extracted multipart ZIP to {0}' -f `$destination)"
    )
    Set-Content -LiteralPath $extractScriptPath -Value $extractScript -Encoding ASCII

    $partsManifestPath = Join-Path -Path $PartsDir -ChildPath 'parts-manifest.txt'
    $manifestLines = @(
        "SourceZip: $ZipPath",
        "PartCount: $($createdPartNames.Count)",
        "RequestedPartCount: $PartCount",
        "ZipSizeBytes: $zipSizeBytes",
        "Format: raw-byte-split",
        "CombineScript: combine.ps1",
        "ExtractScript: extract_all.ps1",
        ''
    ) + @(
        foreach ($partName in $createdPartNames) {
            $partPath = Join-Path -Path $PartsDir -ChildPath $partName
            '{0} {1}' -f $partName, (Get-Item -LiteralPath $partPath).Length
        }
    )
    Set-Content -LiteralPath $partsManifestPath -Value $manifestLines -Encoding ASCII
}

if (-not (Test-Path -LiteralPath $UpdaterScript -PathType Leaf)) {
    throw "Missing updater script: $UpdaterScript"
}

if ([string]::IsNullOrWhiteSpace($Namespace)) {
    $Namespace = Get-NamespaceFromDeploymentEnv
}

if (-not $SkipBuild) {
    $buildArgs = @{
        BackendBaseUrl = $BackendBaseUrl
    }
    if (-not [string]::IsNullOrWhiteSpace($ClientUpdateBaseUrl)) {
        $buildArgs.ClientUpdateBaseUrl = $ClientUpdateBaseUrl
    }
    if (-not [string]::IsNullOrWhiteSpace($FlutterVersion)) {
        $buildArgs.FlutterVersion = $FlutterVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($FlutterCacheRoot)) {
        $buildArgs.FlutterCacheRoot = $FlutterCacheRoot
    }
    if ($RequireFlutterVersion) {
        $buildArgs.RequireFlutterVersion = $true
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
Assert-ClientUpdateZipContents -ZipPath $PortableZip

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
$packageDirName = "sync_windows_agent-$safeVersion-$commit"
$packageOutputRoot = Join-Path -Path $OutputDir -ChildPath 'packages'
$packageOutputDir = Join-Path -Path $packageOutputRoot -ChildPath $packageDirName
$packageFilesManifest = Join-Path -Path $packageOutputDir -ChildPath 'files.json'

Copy-Item -LiteralPath $PortableZip -Destination $versionedZip -Force
Copy-Item -LiteralPath $PortableZip -Destination $latestZip -Force
Copy-Item -LiteralPath $UpdaterScript -Destination $publishedUpdater -Force

if (Test-Path -LiteralPath $packageOutputDir) {
    Remove-Item -LiteralPath $packageOutputDir -Recurse -Force
}
New-Item -Path $packageOutputDir -ItemType Directory -Force | Out-Null
$extractRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("sql-sync-client-publish-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -Path $extractRoot -ItemType Directory -Force | Out-Null
try {
    $zipExtractDir = Join-Path -Path $extractRoot -ChildPath 'extract'
    Expand-Archive -LiteralPath $PortableZip -DestinationPath $zipExtractDir -Force
    $portableDir = Get-SingleChildDirectory -Path $zipExtractDir
    Get-ChildItem -LiteralPath $portableDir -Force |
        Copy-Item -Destination $packageOutputDir -Recurse -Force
}
finally {
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$zipHash = (Get-FileHash -LiteralPath $versionedZip -Algorithm SHA256).Hash.ToLowerInvariant()
$zipSize = (Get-Item -LiteralPath $versionedZip).Length
$publicRoot = $PublicBaseUrl.TrimEnd('/')
$filesManifest = New-PortableFilesManifest `
    -PortableDir $packageOutputDir `
    -PublicRoot $publicRoot `
    -PackageDirName $packageDirName `
    -Version $version `
    -Commit $commit
$filesManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $packageFilesManifest -Encoding ASCII
$manifest = [ordered]@{
    version = $version
    commit = $commit
    releaseDate = $releaseDate
    packageType = 'files-v1'
    filesManifestUrl = "$publicRoot/packages/$packageDirName/files.json"
    zipUrl = "$publicRoot/$zipName"
    updateScriptUrl = "$publicRoot/update.ps1"
    sha256 = $zipHash
    sizeBytes = $zipSize
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $latestManifest -Encoding ASCII

Write-Host "Client update artifacts written to $OutputDir"
Write-Host "Manifest: $latestManifest"
Write-Host "ZIP:      $versionedZip"
Write-Host "Files:    $packageOutputDir"

if ([string]::IsNullOrWhiteSpace($SshTarget)) {
    Write-Host 'No -SshTarget supplied; skipping live upload.'
    return
}

if ([string]::IsNullOrWhiteSpace($Namespace)) {
    throw 'Namespace is required for live upload. Pass -Namespace or keep deployment/chart/.env available.'
}

$remoteStage = "/tmp/sql-sync-client-update-$([guid]::NewGuid().ToString('N'))"
Invoke-CheckedNative -Description "Creating remote staging directory on $SshTarget..." -Command {
    & ssh $SshTarget "mkdir -p '$remoteStage/packages'"
}
try {
    Invoke-CheckedNative -Description 'Uploading staged client artifacts to SSH target...' -Command {
        & scp $latestManifest $versionedZip $latestZip $publishedUpdater "$SshTarget`:$remoteStage/"
    }
    Invoke-CheckedNative -Description 'Uploading staged differential package to SSH target...' -Command {
        & scp -r $packageOutputDir "$SshTarget`:$remoteStage/packages/"
    }
    $podOutput = & ssh $SshTarget "kubectl get pods -n '$Namespace' -l app.kubernetes.io/component=frontend -o name"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list frontend pods in namespace $Namespace"
    }
    $pods = @(
        $podOutput -split "`n" |
            ForEach-Object { $_.Trim() -replace '^pod/', '' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($pods.Count -eq 0) {
        throw "No frontend pods found in namespace $Namespace"
    }

    foreach ($pod in $pods) {
        Invoke-CheckedNative -Description "Publishing client update files to pod $pod..." -Command {
            & ssh $SshTarget "kubectl exec -n '$Namespace' '$pod' -- mkdir -p '$RemoteUpdatesDir/packages/$packageDirName' && kubectl cp '$remoteStage/latest.json' '$Namespace/$pod`:$RemoteUpdatesDir/latest.json' && kubectl cp '$remoteStage/$zipName' '$Namespace/$pod`:$RemoteUpdatesDir/$zipName' && kubectl cp '$remoteStage/sync_windows_agent_latest.zip' '$Namespace/$pod`:$RemoteUpdatesDir/sync_windows_agent_latest.zip' && kubectl cp '$remoteStage/update.ps1' '$Namespace/$pod`:$RemoteUpdatesDir/update.ps1' && kubectl cp '$remoteStage/packages/$packageDirName/.' '$Namespace/$pod`:$RemoteUpdatesDir/packages/$packageDirName'"
        }
    }

    Write-Host "Uploaded client update $version ($commit) to $($pods.Count) frontend pod(s)."
}
finally {
    & ssh $SshTarget "rm -rf '$remoteStage'" | Out-Null
}

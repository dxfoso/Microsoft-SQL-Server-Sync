param(
    [string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call',
    [string] $ClientUpdateBaseUrl = '',
    [string] $FlutterVersion = '',
    [string] $FlutterCacheRoot = '',
    [string] $SymmetricDsVersion = '3.16.10',
    [string] $SymmetricDsDownloadUrl = '',
    [switch] $RequireFlutterVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$MinimumFlutterVersion = [version]'3.41.9'
$FlutterReleaseIndexUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'

. (Join-Path -Path $PSScriptRoot -ChildPath 'scripts\windows_agent_build.ps1')

function Get-DefaultFlutterCacheRoot {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Could not determine LocalApplicationData for the Flutter SDK cache.'
    }

    return Join-Path -Path $localAppData -ChildPath 'MicrosoftSqlServerSync\flutter-sdk-cache'
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string] $ChildPath,
        [Parameter(Mandatory = $true)][string] $ParentPath,
        [Parameter(Mandatory = $true)][string] $Purpose
    )

    $childFull = Get-FullPath -Path $ChildPath
    $parentFull = Get-FullPath -Path $ParentPath
    $trimChars = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $parentPrefix = $parentFull.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar

    if ($childFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $childFull.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing $Purpose outside output root. Path: $childFull Output root: $parentFull"
    }
}

function Remove-OutputPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $OutputRoot,
        [Parameter(Mandatory = $true)][string] $Purpose
    )

    if (Test-Path -LiteralPath $Path) {
        Assert-ChildPath -ChildPath $Path -ParentPath $OutputRoot -Purpose $Purpose
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Stop-ProcessesUnderPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $targetFull = Get-FullPath -Path $Path
    $trimChars = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $targetPrefix = $targetFull.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ([string]::IsNullOrWhiteSpace($_.ExecutablePath)) {
                return $false
            }

            $executablePath = [System.IO.Path]::GetFullPath($_.ExecutablePath)
            return $executablePath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        } |
        ForEach-Object {
            Write-Host "Stopping process using portable output: $($_.Name) [$($_.ProcessId)]"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Invoke-NativeCommand {
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

function Get-FlutterVersion {
    param([Parameter(Mandatory = $true)][string] $FlutterCommand)

    $versionOutput = & $FlutterCommand --version 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to run flutter --version using: $FlutterCommand"
    }

    $firstLine = @($versionOutput | Where-Object { $_ -match '^Flutter\s+[0-9]+\.[0-9]+\.[0-9]+\b' } | Select-Object -First 1)[0]
    if ([string]::IsNullOrWhiteSpace($firstLine)) {
        throw "Unable to find Flutter version line in: $($versionOutput -join "`n")"
    }
    $match = [regex]::Match($firstLine, '^Flutter\s+([0-9]+\.[0-9]+\.[0-9]+)\b')
    if (-not $match.Success) {
        throw "Unable to parse Flutter version from: $firstLine"
    }

    return [pscustomobject]@{
        Version = [version]$match.Groups[1].Value
        Text = ($versionOutput -join "`n")
    }
}

function Assert-FlutterVersion {
    param([Parameter(Mandatory = $true)] $FlutterVersionInfo)

    if ($FlutterVersionInfo.Version -lt $MinimumFlutterVersion) {
        throw "Flutter $($FlutterVersionInfo.Version) is too old for the Windows portable build. Use Flutter $MinimumFlutterVersion or newer, then rebuild the portable package."
    }

    Write-Host "Flutter version: $($FlutterVersionInfo.Version)"
}

function Get-FlutterReleaseIndex {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $FlutterReleaseIndexUrl
    return $response.Content | ConvertFrom-Json
}

function Get-FlutterReleaseInfo {
    param([Parameter(Mandatory = $true)][string] $Version)

    $releaseIndex = Get-FlutterReleaseIndex
    $release = @($releaseIndex.releases | Where-Object {
            $_.channel -eq 'stable' -and
            $_.dart_sdk_arch -eq 'x64' -and
            $_.version -eq $Version
        } | Select-Object -First 1)[0]

    if ($null -eq $release) {
        throw "Could not find Flutter Windows x64 stable release $Version in $FlutterReleaseIndexUrl"
    }

    return [pscustomobject]@{
        Version = $Version
        ArchiveUrl = ($releaseIndex.base_url.TrimEnd('/') + '/' + $release.archive.TrimStart('/'))
        Sha256 = $release.sha256
        Hash = $release.hash
        ReleaseDate = $release.release_date
    }
}

function Get-CachedFlutterCommandPath {
    param(
        [Parameter(Mandatory = $true)][string] $CacheRoot,
        [Parameter(Mandatory = $true)][string] $Version
    )

    return Join-Path -Path $CacheRoot -ChildPath "$Version\flutter\bin\flutter.bat"
}

function Test-FlutterCommandAvailable {
    param([Parameter(Mandatory = $true)][string] $FlutterCommand)

    return (Test-Path -LiteralPath $FlutterCommand -PathType Leaf)
}

function Get-FlutterSdkRootFromCommand {
    param([Parameter(Mandatory = $true)][string] $FlutterCommand)

    $commandPath = $FlutterCommand
    if ($FlutterCommand -eq 'flutter') {
        $resolvedCommand = Get-Command flutter -ErrorAction Stop
        $commandPath = $resolvedCommand.Source
    }

    $commandFullPath = Get-FullPath -Path $commandPath
    $binDir = Split-Path -Path $commandFullPath -Parent
    return Split-Path -Path $binDir -Parent
}

function Get-FlutterReleaseEngineDllPath {
    param([Parameter(Mandatory = $true)][string] $FlutterCommand)

    $flutterRoot = Get-FlutterSdkRootFromCommand -FlutterCommand $FlutterCommand
    $releaseDll = Join-Path -Path $flutterRoot -ChildPath 'bin\cache\artifacts\engine\windows-x64-release\flutter_windows.dll'
    if (-not (Test-Path -LiteralPath $releaseDll -PathType Leaf)) {
        throw "Flutter release engine DLL is missing: $releaseDll"
    }

    return $releaseDll
}

function Assert-FileSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )

    $actualSha256 = $null
    $attemptCount = 5
    for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
        try {
            $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            break
        } catch {
            if ($attempt -eq $attemptCount) {
                throw
            }

            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }

    if (-not $actualSha256.Equals($ExpectedSha256.ToLowerInvariant(), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Flutter SDK archive hash mismatch. Expected $ExpectedSha256 but got $actualSha256 for $Path"
    }
}

function Assert-SameFileSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $ActualPath,
        [Parameter(Mandatory = $true)][string] $ExpectedPath,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $actualHash = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
    $expectedHash = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description hash mismatch. Actual: $ActualPath Expected: $ExpectedPath"
    }
}

function Get-VerifiedFlutterArchivePath {
    param(
        [Parameter(Mandatory = $true)][string] $DownloadsDir,
        [Parameter(Mandatory = $true)] $ReleaseInfo
    )

    $zipPath = Join-Path -Path $DownloadsDir -ChildPath "flutter_windows_$($ReleaseInfo.Version)-stable.zip"
    $downloadAttempted = $false

    while ($true) {
        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
            Write-Host "Downloading Flutter SDK $($ReleaseInfo.Version) from $($ReleaseInfo.ArchiveUrl)"
            Invoke-WebRequest -UseBasicParsing -Uri $ReleaseInfo.ArchiveUrl -OutFile $zipPath
            $downloadAttempted = $true
        } else {
            Write-Host "Using cached Flutter SDK archive: $zipPath"
        }

        try {
            Assert-FileSha256 -Path $zipPath -ExpectedSha256 $ReleaseInfo.Sha256
            return $zipPath
        } catch {
            if ($downloadAttempted) {
                throw
            }

            Write-Warning "Cached Flutter SDK archive failed hash verification. Removing it and downloading a fresh copy."
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
            $downloadAttempted = $true
        }
    }
}

function Install-CachedFlutterSdk {
    param(
        [Parameter(Mandatory = $true)][string] $CacheRoot,
        [Parameter(Mandatory = $true)][string] $Version
    )

    $flutterCommand = Get-CachedFlutterCommandPath -CacheRoot $CacheRoot -Version $Version
    if (Test-FlutterCommandAvailable -FlutterCommand $flutterCommand) {
        return $flutterCommand
    }

    $releaseInfo = Get-FlutterReleaseInfo -Version $Version
    $cacheRootFull = Get-FullPath -Path $CacheRoot
    $versionRoot = Join-Path -Path $cacheRootFull -ChildPath $Version
    $downloadsDir = Join-Path -Path $cacheRootFull -ChildPath 'downloads'
    $tempRoot = Join-Path -Path $cacheRootFull -ChildPath ("tmp-$Version-" + [guid]::NewGuid().ToString('N'))
    $extractRoot = Join-Path -Path $tempRoot -ChildPath 'extract'

    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
    $zipPath = Get-VerifiedFlutterArchivePath -DownloadsDir $downloadsDir -ReleaseInfo $releaseInfo

    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    try {
        Write-Host "Extracting Flutter SDK $Version..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

        $extractedFlutterDir = Join-Path -Path $extractRoot -ChildPath 'flutter'
        if (-not (Test-Path -LiteralPath $extractedFlutterDir -PathType Container)) {
            throw "Flutter SDK archive did not extract the expected flutter directory: $extractedFlutterDir"
        }

        if (Test-Path -LiteralPath $versionRoot) {
            Remove-Item -LiteralPath $versionRoot -Recurse -Force
        }

        New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
        Move-Item -LiteralPath $extractedFlutterDir -Destination (Join-Path -Path $versionRoot -ChildPath 'flutter')
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-FlutterCommandAvailable -FlutterCommand $flutterCommand)) {
        throw "Flutter SDK $Version was extracted but flutter.bat is missing: $flutterCommand"
    }

    return $flutterCommand
}

function Resolve-FlutterToolchain {
    param(
        [string] $Version,
        [string] $CacheRoot,
        [switch] $RequireFlutterVersion
    )

    $currentFlutter = Get-Command flutter -ErrorAction SilentlyContinue
    $usePinnedVersion = -not [string]::IsNullOrWhiteSpace($Version)

    if ($null -ne $currentFlutter) {
        $currentVersionInfo = Get-FlutterVersion -FlutterCommand $currentFlutter.Source
        if (-not $usePinnedVersion) {
            Assert-FlutterVersion -FlutterVersionInfo $currentVersionInfo
            Write-Host "Using PATH Flutter $($currentVersionInfo.Version) for Windows portable build."
            return [pscustomobject]@{
                Command = 'flutter'
                VersionInfo = $currentVersionInfo
                Source = 'PATH'
            }
        }

        if ($currentVersionInfo.Version -eq [version]$Version) {
            Assert-FlutterVersion -FlutterVersionInfo $currentVersionInfo
            Write-Host "Using PATH Flutter $Version for Windows portable build."
            return [pscustomobject]@{
                Command = 'flutter'
                VersionInfo = $currentVersionInfo
                Source = 'PATH'
            }
        }
    }

    if (-not $usePinnedVersion) {
        throw 'Flutter is not installed or not available in PATH.'
    }

    $flutterCommand = $null
    $flutterVersionInfo = $null
    try {
        $flutterCommand = Install-CachedFlutterSdk -CacheRoot $CacheRoot -Version $Version
        $flutterVersionInfo = Get-FlutterVersion -FlutterCommand $flutterCommand
        Assert-FlutterVersion -FlutterVersionInfo $flutterVersionInfo
        if ($flutterVersionInfo.Version -ne [version]$Version) {
            throw "Expected cached Flutter $Version but found $($flutterVersionInfo.Version) at $flutterCommand"
        }
    } catch {
        if ($RequireFlutterVersion) {
            throw
        }

        if ($null -eq $currentFlutter) {
            throw
        }

        $fallbackVersionInfo = Get-FlutterVersion -FlutterCommand $currentFlutter.Source
        Assert-FlutterVersion -FlutterVersionInfo $fallbackVersionInfo
        $warningMessage = ("Falling back to PATH Flutter {0} because Flutter {1} is not available locally. " +
                           "Use -RequireFlutterVersion to fail instead of falling back.") -f $fallbackVersionInfo.Version, $Version
        Write-Warning $warningMessage
        return [pscustomobject]@{
            Command = 'flutter'
            VersionInfo = $fallbackVersionInfo
            Source = 'PATH fallback'
        }
    }

    Write-Host "Using cached Flutter $Version from $flutterCommand"
    return [pscustomobject]@{
        Command = $flutterCommand
        VersionInfo = $flutterVersionInfo
        Source = 'cache'
    }
}

function Get-BinaryName {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $cmakePath = Join-Path -Path $ProjectPath -ChildPath 'windows\CMakeLists.txt'
    if (Test-Path -LiteralPath $cmakePath) {
        $match = Get-Content -LiteralPath $cmakePath |
            Select-String -Pattern '^\s*set\s*\(\s*BINARY_NAME\s+"([^"]+)"\s*\)' |
            Select-Object -First 1

        if ($match) {
            return $match.Matches[0].Groups[1].Value
        }
    }

    return Split-Path -Path $ProjectPath -Leaf
}

function New-DartDefineArgs {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectPath,
        [Parameter(Mandatory = $true)][string] $BackendBaseUrl
    )

    return New-WindowsAgentDartDefineArgs `
        -ProjectPath $ProjectPath `
        -BackendBaseUrl $BackendBaseUrl `
        -RepoRoot $PSScriptRoot `
        -ClientUpdateBaseUrl $ClientUpdateBaseUrl
}

function Invoke-FlutterCommand {
    param(
        [Parameter(Mandatory = $true)][string] $FlutterCommand,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory
    )

    $process = Start-Process -FilePath $FlutterCommand `
        -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -Wait `
        -PassThru `
        -NoNewWindow

    $script:LASTEXITCODE = $process.ExitCode
}

function Add-SearchDir {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Dirs,
        [AllowNull()] [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $fullPath = Get-FullPath -Path $Path
    if ((Test-Path -LiteralPath $fullPath -PathType Container) -and
        -not $Dirs.Contains($fullPath)) {
        [void] $Dirs.Add($fullPath)
    }
}

function Get-VCRuntimeSearchDirs {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $dirs = [System.Collections.Generic.List[string]]::new()
    Add-SearchDir -Dirs $dirs -Path (Join-Path -Path $ProjectPath -ChildPath 'portable_release')
    Add-SearchDir -Dirs $dirs -Path (Join-Path -Path $ProjectPath -ChildPath 'release')

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $vswhere = Join-Path -Path $programFilesX86 -ChildPath 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
            $installations = @(& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
            foreach ($installation in $installations) {
                $redistRoot = Join-Path -Path $installation -ChildPath 'VC\Redist\MSVC'
                if (Test-Path -LiteralPath $redistRoot -PathType Container) {
                    Get-ChildItem -LiteralPath $redistRoot -Directory -Recurse -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -match '\\x64\\' } |
                        ForEach-Object { Add-SearchDir -Dirs $dirs -Path $_.FullName }
                }
            }
        }
    }

    Add-SearchDir -Dirs $dirs -Path (Join-Path -Path $env:WINDIR -ChildPath 'System32')
    return $dirs
}

function Copy-VCRuntimeDlls {
    param(
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $ProjectPath
    )

    $runtimeDlls = @(
        'concrt140.dll',
        'msvcp140.dll',
        'msvcp140_1.dll',
        'msvcp140_2.dll',
        'msvcp140_atomic_wait.dll',
        'msvcp140_codecvt_ids.dll',
        'vccorlib140.dll',
        'vcruntime140.dll',
        'vcruntime140_1.dll',
        'vcruntime140_threads.dll'
    )

    $searchDirs = Get-VCRuntimeSearchDirs -ProjectPath $ProjectPath
    $copied = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($dll in $runtimeDlls) {
        $source = $null
        foreach ($dir in $searchDirs) {
            $candidate = Join-Path -Path $dir -ChildPath $dll
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $source = $candidate
                break
            }
        }

        if ($source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path -Path $Destination -ChildPath $dll) -Force
            [void] $copied.Add($dll)
        } else {
            [void] $missing.Add($dll)
        }
    }

    if ($copied.Count -gt 0) {
        Write-Host "Included VC runtime DLLs: $($copied -join ', ')"
    }

    if ($missing.Count -gt 0) {
        Write-Warning "Could not find optional VC runtime DLLs: $($missing -join ', ')"
    }
}

function Get-SymmetricDsDownloadUrl {
    param([Parameter(Mandatory = $true)][string] $Version)

    $minorVersion = [regex]::Match($Version, '^([0-9]+\.[0-9]+)').Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($minorVersion)) {
        throw "Could not derive SymmetricDS minor version from: $Version"
    }
    return "https://sourceforge.net/projects/symmetricds/files/symmetricds/symmetricds-$minorVersion/symmetric-server-$Version.zip/download"
}

function Test-ZipFileSignature {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 4) {
            return $false
        }
        $buffer = New-Object byte[] 4
        [void] $stream.Read($buffer, 0, 4)
        return $buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B
    }
    finally {
        $stream.Dispose()
    }
}

function Resolve-SourceForgeMirrorUrl {
    param([Parameter(Mandatory = $true)][string] $HtmlContent)

    $match = [regex]::Match($HtmlContent, 'url=(https://downloads\.sourceforge\.net/[^"'']+)')
    if (-not $match.Success) {
        return ''
    }
    return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
}

function Save-VerifiedZip {
    param(
        [Parameter(Mandatory = $true)][string] $Url,
        [Parameter(Mandatory = $true)][string] $OutFile,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $tempFile = "$OutFile.tmp"
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force
    }
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tempFile -MaximumRedirection 10
    if (Test-ZipFileSignature -Path $tempFile) {
        Move-Item -LiteralPath $tempFile -Destination $OutFile -Force
        return
    }

    $content = Get-Content -LiteralPath $tempFile -Raw -ErrorAction SilentlyContinue
    $mirrorUrl = if ($content) { Resolve-SourceForgeMirrorUrl -HtmlContent $content } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($mirrorUrl)) {
        Invoke-WebRequest -UseBasicParsing -Uri $mirrorUrl -OutFile $tempFile -MaximumRedirection 10
        if (Test-ZipFileSignature -Path $tempFile) {
            Move-Item -LiteralPath $tempFile -Destination $OutFile -Force
            return
        }
    }

    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
    throw "$Description did not download as a ZIP archive."
}

function Install-SymmetricDsRuntime {
    param(
        [Parameter(Mandatory = $true)][string] $Version,
        [AllowEmptyString()][string] $DownloadUrl,
        [Parameter(Mandatory = $true)][string] $PortableDir,
        [Parameter(Mandatory = $true)][string] $CacheRoot
    )

    if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
        $DownloadUrl = Get-SymmetricDsDownloadUrl -Version $Version
    }

    $downloadsDir = Join-Path -Path $CacheRoot -ChildPath 'downloads'
    $archivePath = Join-Path -Path $downloadsDir -ChildPath "symmetric-server-$Version.zip"
    $extractRoot = Join-Path -Path $CacheRoot -ChildPath "symmetricds-$Version"
    $tempRoot = Join-Path -Path $CacheRoot -ChildPath ("tmp-symmetricds-$Version-" + [guid]::NewGuid().ToString('N'))
    $destination = Join-Path -Path $PortableDir -ChildPath 'symmetricds'

    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null

    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Host "Downloading SymmetricDS $Version from $DownloadUrl"
        Save-VerifiedZip -Url $DownloadUrl -OutFile $archivePath -Description "SymmetricDS $Version"
    } else {
        Write-Host "Using cached SymmetricDS archive: $archivePath"
        if (-not (Test-ZipFileSignature -Path $archivePath)) {
            Write-Warning "Cached SymmetricDS archive is not a ZIP. Removing and downloading a fresh copy."
            Remove-Item -LiteralPath $archivePath -Force
            Save-VerifiedZip -Url $DownloadUrl -OutFile $archivePath -Description "SymmetricDS $Version"
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path -Path $extractRoot -ChildPath 'bin') -PathType Container)) {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            Write-Host "Extracting SymmetricDS $Version..."
            Expand-Archive -LiteralPath $archivePath -DestinationPath $tempRoot -Force
            $extractedRoot = Get-ChildItem -LiteralPath $tempRoot -Directory -Recurse -ErrorAction Stop |
                Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'bin') -PathType Container } |
                Select-Object -First 1
            if ($null -eq $extractedRoot) {
                throw "SymmetricDS archive did not contain a directory with a bin folder: $archivePath"
            }
            if (Test-Path -LiteralPath $extractRoot) {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force
            }
            Move-Item -LiteralPath $extractedRoot.FullName -Destination $extractRoot
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $symBat = Join-Path -Path $extractRoot -ChildPath 'bin\sym.bat'
    if (-not (Test-Path -LiteralPath $symBat -PathType Leaf)) {
        throw "SymmetricDS runtime is missing bin\sym.bat after extraction: $extractRoot"
    }

    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    Copy-Item -LiteralPath $extractRoot -Destination $destination -Recurse -Force
    Write-Host "Included SymmetricDS runtime: $destination"
}

function New-PortableLauncher {
    param(
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $ExeName
    )

    $launcherPath = Join-Path -Path $Destination -ChildPath 'run_portable.bat'
    $launcher = @"
@echo off
setlocal

set "APP_DIR=%~dp0"
set "APP_EXE=%APP_DIR%$ExeName"
set "LOG_FILE=%APP_DIR%portable.log"
set "STARTUP_LOG=%APP_DIR%sync_windows_agent_startup.log"

if not exist "%APP_EXE%" (
  echo Missing executable: %APP_EXE%
  exit /b 1
)

echo Starting portable app: %APP_EXE%
echo Writing console output to: %LOG_FILE%
echo Writing startup trace to: %STARTUP_LOG%
echo.

"%APP_EXE%" %* > "%LOG_FILE%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo Portable app exited with code %EXIT_CODE%.
echo Console output: %LOG_FILE%
echo Startup trace: %STARTUP_LOG%
exit /b %EXIT_CODE%
"@

    Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding ASCII
}

function Get-PortableRequiredFiles {
    param([Parameter(Mandatory = $true)][string] $ExeName)

    return @(
        $ExeName,
        'flutter_windows.dll',
        'run_portable.bat',
        'update.ps1',
        'symmetricds\bin\sym.bat'
    )
}

function Sync-WindowsReleasePayload {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectPath,
        [Parameter(Mandatory = $true)][string] $ReleaseDir,
        [Parameter(Mandatory = $true)][string] $FlutterReleaseEngineDll
    )

    $releaseDataDir = Join-Path -Path $ReleaseDir -ChildPath 'data'
    $flutterAssetsSource = Join-Path -Path $ProjectPath -ChildPath 'build\flutter_assets'
    $flutterAssetsDestination = Join-Path -Path $releaseDataDir -ChildPath 'flutter_assets'
    $nativeAssetsSource = Join-Path -Path $ProjectPath -ChildPath 'build\native_assets\windows'
    $appSoSource = Join-Path -Path $ProjectPath -ChildPath 'build\windows\app.so'
    $ephemeralDir = Join-Path -Path $ProjectPath -ChildPath 'windows\flutter\ephemeral'
    $pluginReleaseRoot = Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64\plugins'

    New-Item -Path $ReleaseDir -ItemType Directory -Force | Out-Null
    New-Item -Path $releaseDataDir -ItemType Directory -Force | Out-Null

    foreach ($fileName in @('flutter_windows.dll', 'icudtl.dat')) {
        $sourcePath = Join-Path -Path $ephemeralDir -ChildPath $fileName
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            $destinationPath = if ($fileName -eq 'icudtl.dat') {
                Join-Path -Path $releaseDataDir -ChildPath $fileName
            } else {
                Join-Path -Path $ReleaseDir -ChildPath $fileName
            }

            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        }
    }

    Copy-Item -LiteralPath $FlutterReleaseEngineDll -Destination (Join-Path -Path $ReleaseDir -ChildPath 'flutter_windows.dll') -Force

    if (Test-Path -LiteralPath $pluginReleaseRoot -PathType Container) {
        Get-ChildItem -LiteralPath $pluginReleaseRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $pluginReleaseDir = Join-Path -Path $_.FullName -ChildPath 'Release'
                if (Test-Path -LiteralPath $pluginReleaseDir -PathType Container) {
                    Get-ChildItem -LiteralPath $pluginReleaseDir -Filter '*.dll' -File -ErrorAction SilentlyContinue |
                        Copy-Item -Destination $ReleaseDir -Force
                }
            }
    }

    if (Test-Path -LiteralPath $flutterAssetsSource -PathType Container) {
        if (Test-Path -LiteralPath $flutterAssetsDestination) {
            Remove-Item -LiteralPath $flutterAssetsDestination -Recurse -Force
        }

        Copy-Item -LiteralPath $flutterAssetsSource -Destination $flutterAssetsDestination -Recurse -Force
    }

    if (Test-Path -LiteralPath $nativeAssetsSource -PathType Container) {
        Get-ChildItem -LiteralPath $nativeAssetsSource -Force |
            Copy-Item -Destination $ReleaseDir -Recurse -Force
    }

    if (Test-Path -LiteralPath $appSoSource -PathType Leaf) {
        Copy-Item -LiteralPath $appSoSource -Destination (Join-Path -Path $releaseDataDir -ChildPath 'app.so') -Force
    }
}

function Write-PortableManifest {
    param(
        [Parameter(Mandatory = $true)][string] $PortableDir,
        [Parameter(Mandatory = $true)][string] $ZipPath,
        [Parameter(Mandatory = $true)][string] $RepoRoot,
        [Parameter(Mandatory = $true)] $FlutterVersionInfo
    )

    $manifestPath = Join-Path -Path $PortableDir -ChildPath 'portable-manifest.txt'
    $entries = Get-ChildItem -LiteralPath $PortableDir -Recurse -File -Force |
        Sort-Object FullName |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($PortableDir.Length).TrimStart('\', '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            '{0} {1}' -f $hash, $relativePath.Replace('\', '/')
        }

    $manifestLines = @(
        "BuiltAtUtc: $([DateTime]::UtcNow.ToString('o'))",
        "PortableDir: $PortableDir",
        "ZipPath: $ZipPath",
        "SourceCommit: $(Get-WindowsAgentGitCommitHash -RepoRoot $RepoRoot)",
        "FlutterVersion: $($FlutterVersionInfo.Version)",
        ''
    ) + $entries

    Set-Content -LiteralPath $manifestPath -Value $manifestLines -Encoding ASCII
}

function Assert-PortablePayload {
    param(
        [Parameter(Mandatory = $true)][string] $ReleaseDir,
        [Parameter(Mandatory = $true)][string] $PortableDir,
        [Parameter(Mandatory = $true)][string] $ExeName,
        [switch] $RequireVCRuntime
    )

    $releaseFiles = Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File -Force
    if ($releaseFiles.Count -eq 0) {
        throw "Release directory is empty: $ReleaseDir"
    }

    $portableFiles = Get-ChildItem -LiteralPath $PortableDir -Recurse -File -Force
    if ($portableFiles.Count -eq 0) {
        throw "Portable directory is empty: $PortableDir"
    }

    $releaseRelativePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $releaseFiles) {
        $relativePath = $file.FullName.Substring($ReleaseDir.Length).TrimStart('\', '/').Replace('\', '/')
        [void] $releaseRelativePaths.Add($relativePath)
    }

    $portableRelativePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $portableFiles) {
        $relativePath = $file.FullName.Substring($PortableDir.Length).TrimStart('\', '/').Replace('\', '/')
        [void] $portableRelativePaths.Add($relativePath)
    }

    $missingReleaseFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in $releaseRelativePaths) {
        if (-not $portableRelativePaths.Contains($relativePath)) {
            [void] $missingReleaseFiles.Add($relativePath)
        }
    }

    if ($missingReleaseFiles.Count -gt 0) {
        throw "Portable directory is missing release payload files: $($missingReleaseFiles -join ', ')"
    }

    $requiredFiles = Get-PortableRequiredFiles -ExeName $ExeName
    foreach ($requiredFile in $requiredFiles) {
        $requiredPath = Join-Path -Path $PortableDir -ChildPath $requiredFile
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Portable output is missing required file: $requiredFile"
        }
    }

    $aotLibraryPath = Join-Path -Path $PortableDir -ChildPath 'data\app.so'
    if (-not (Test-Path -LiteralPath $aotLibraryPath -PathType Leaf)) {
        throw "Portable output is missing release AOT library: data/app.so"
    }

    $debugKernelPath = Join-Path -Path $PortableDir -ChildPath 'data\flutter_assets\kernel_blob.bin'
    if (Test-Path -LiteralPath $debugKernelPath -PathType Leaf) {
        throw "Portable output contains debug kernel_blob.bin; refusing to publish a non-release payload."
    }

    $payloadDlls = Get-ChildItem -LiteralPath $PortableDir -Filter '*.dll' -File -Force
    if ($payloadDlls.Count -eq 0) {
        throw "Portable output contains no DLLs: $PortableDir"
    }

    if ($RequireVCRuntime) {
        $runtimeDlls = @(
            'concrt140.dll',
            'msvcp140.dll',
            'vcruntime140.dll'
        )
        foreach ($dll in $runtimeDlls) {
            $dllPath = Join-Path -Path $PortableDir -ChildPath $dll
            if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
                throw "Portable output is missing VC runtime DLL: $dll"
            }
        }
    }
}

function Assert-PortableZipContents {
    param(
        [Parameter(Mandatory = $true)][string] $ZipPath,
        [Parameter(Mandatory = $true)][string] $PortableName,
        [Parameter(Mandatory = $true)][string] $ExeName,
        [switch] $RequireVCRuntime
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entryNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            [void] $entryNames.Add($entry.FullName.Replace('\', '/'))
        }

        $requiredEntries = @(
            "$PortableName/$ExeName",
            "$PortableName/flutter_windows.dll",
            "$PortableName/data/app.so",
            "$PortableName/run_portable.bat",
            "$PortableName/update.ps1",
            "$PortableName/portable-manifest.txt",
            "$PortableName/symmetricds/bin/sym.bat"
        )
        if ($RequireVCRuntime) {
            $requiredEntries += @(
                "$PortableName/concrt140.dll",
                "$PortableName/msvcp140.dll",
                "$PortableName/vcruntime140.dll"
            )
        }

        foreach ($requiredEntry in $requiredEntries) {
            if (-not $entryNames.Contains($requiredEntry)) {
                throw "Portable zip is missing required entry: $requiredEntry"
            }
        }

        $debugKernelEntry = "$PortableName/data/flutter_assets/kernel_blob.bin"
        if ($entryNames.Contains($debugKernelEntry)) {
            throw "Portable zip contains debug kernel_blob.bin; refusing to publish a non-release payload."
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-DirectorySize {
    param([Parameter(Mandatory = $true)][string] $Path)

    $sum = Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
        Measure-Object -Property Length -Sum
    return [long] $sum.Sum
}

Push-Location $PSScriptRoot
try {
    $ProjectPath = Get-FullPath -Path (Join-Path -Path $PSScriptRoot -ChildPath 'sync_windows_agent')
    $OutputRoot = Get-FullPath -Path $PSScriptRoot
    $PortableName = ''
    if (-not [string]::IsNullOrWhiteSpace($FlutterVersion) -and [string]::IsNullOrWhiteSpace($FlutterCacheRoot)) {
        $FlutterCacheRoot = Get-DefaultFlutterCacheRoot
    }
    if ([string]::IsNullOrWhiteSpace($FlutterCacheRoot)) {
        $FlutterCacheRoot = Get-DefaultFlutterCacheRoot
    }

    $flutterToolchain = Resolve-FlutterToolchain `
        -Version $FlutterVersion `
        -CacheRoot $FlutterCacheRoot `
        -RequireFlutterVersion:$RequireFlutterVersion
    $flutterCommand = $flutterToolchain.Command
    $flutterVersionInfo = $flutterToolchain.VersionInfo
    Initialize-WindowsAgentBuildEnvironment

    if (-not (Test-Path -LiteralPath (Join-Path -Path $ProjectPath -ChildPath 'pubspec.yaml') -PathType Leaf)) {
        throw "Could not find Flutter pubspec.yaml in project path: $ProjectPath"
    }

    $binaryName = Get-BinaryName -ProjectPath $ProjectPath
    if ([string]::IsNullOrWhiteSpace($PortableName)) {
        $PortableName = "$binaryName-windows-portable"
    }

    $releaseDir = Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64\runner\Release'
    $portableDir = Join-Path -Path $OutputRoot -ChildPath $PortableName
    $zipPath = Join-Path -Path $OutputRoot -ChildPath "$PortableName.zip"
    $exeName = "$binaryName.exe"
    $exePath = Join-Path -Path $releaseDir -ChildPath $exeName

    New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
    Stop-ProcessesUnderPath -Path $portableDir
    Remove-OutputPath -Path $portableDir -OutputRoot $OutputRoot -Purpose 'to remove the old portable directory before build'
    Remove-OutputPath -Path $zipPath -OutputRoot $OutputRoot -Purpose 'to remove the old zip archive before build'

    Push-Location $ProjectPath
    try {
        Stop-WindowsAgentConflictingDevProcesses -ProjectPath $ProjectPath
        Assert-NoWindowsAgentConflictingDevProcesses -ProjectPath $ProjectPath
        Invoke-NativeCommand -Description 'Running flutter pub get...' -Command {
            Invoke-FlutterCommand -FlutterCommand $flutterCommand -Arguments @('pub', 'get') -WorkingDirectory $ProjectPath
        }
        Write-Host "Portable backend URL: $BackendBaseUrl"
        Remove-WindowsAgentBuildArtifacts `
            -ProjectPath $ProjectPath
        $buildDartDefines = New-DartDefineArgs -ProjectPath $ProjectPath -BackendBaseUrl $BackendBaseUrl
        $buildArguments = @('build', 'windows', '--release', '--no-tree-shake-icons') + $buildDartDefines
        Write-Host 'Building Windows release...'
        Invoke-WindowsAgentVisualStudioCommand `
            -Command (@($flutterCommand) + $buildArguments) `
            -WorkingDirectory $ProjectPath

        if ($LASTEXITCODE -ne 0) {
            $canRecoverReleaseInstall = (Test-Path -LiteralPath $exePath -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64\cmake_install.cmake') -PathType Leaf)

            if (-not $canRecoverReleaseInstall) {
                throw "Command failed with exit code $LASTEXITCODE`: Building Windows release..."
            }

            $restoredAotLibrary = Restore-WindowsAgentAotLibrary -ProjectPath $ProjectPath
            if (-not $restoredAotLibrary) {
                Write-Warning 'Flutter release install did not produce build/windows/app.so. Continuing with manual release payload staging.'
            } else {
                Write-Warning 'Flutter release install did not finish, but the release executable and restored AOT library are available. Continuing with manual release payload staging.'
            }
        } else {
            Write-Host 'Windows release build finished successfully.'
        }
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Windows release build did not produce expected executable: $exePath"
    }

    $flutterReleaseEngineDll = Get-FlutterReleaseEngineDllPath -FlutterCommand $flutterCommand
    Sync-WindowsReleasePayload `
        -ProjectPath $ProjectPath `
        -ReleaseDir $releaseDir `
        -FlutterReleaseEngineDll $flutterReleaseEngineDll

    New-Item -Path $portableDir -ItemType Directory -Force | Out-Null
    Get-ChildItem -LiteralPath $releaseDir -Force |
        Copy-Item -Destination $portableDir -Recurse -Force
    Assert-SameFileSha256 `
        -ActualPath (Join-Path -Path $portableDir -ChildPath 'flutter_windows.dll') `
        -ExpectedPath $flutterReleaseEngineDll `
        -Description 'Portable Flutter release engine DLL'

    Copy-VCRuntimeDlls -Destination $portableDir -ProjectPath $ProjectPath
    Install-SymmetricDsRuntime `
        -Version $SymmetricDsVersion `
        -DownloadUrl $SymmetricDsDownloadUrl `
        -PortableDir $portableDir `
        -CacheRoot (Join-Path -Path $FlutterCacheRoot -ChildPath 'symmetricds')

    New-PortableLauncher -Destination $portableDir -ExeName $exeName
    Copy-Item -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'update.ps1') -Destination (Join-Path -Path $portableDir -ChildPath 'update.ps1') -Force
    Write-PortableManifest -PortableDir $portableDir -ZipPath $zipPath -RepoRoot $PSScriptRoot -FlutterVersionInfo $flutterVersionInfo
    Assert-PortablePayload -ReleaseDir $releaseDir -PortableDir $portableDir -ExeName $exeName -RequireVCRuntime

    Write-Host "Creating zip archive..."
    Compress-Archive -LiteralPath $portableDir -DestinationPath $zipPath -Force
    Assert-PortableZipContents -ZipPath $zipPath -PortableName $PortableName -ExeName $exeName -RequireVCRuntime

    $portableSize = Get-DirectorySize -Path $portableDir
    $zipSize = (Get-Item -LiteralPath $zipPath).Length

    Write-Host ''
    Write-Host 'Portable Windows build complete.'
    Write-Host "Folder: $portableDir"
    Write-Host "Zip:    $zipPath"
    Write-Host "EXE:    $(Join-Path -Path $portableDir -ChildPath $exeName)"
    Write-Host ("Folder size: {0:N1} MB" -f ($portableSize / 1MB))
    Write-Host ("Zip size:    {0:N1} MB" -f ($zipSize / 1MB))
}
finally {
    Pop-Location
}

param(
    [string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Get-FlutterAppVersion {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $pubspecPath = Join-Path -Path $ProjectPath -ChildPath 'pubspec.yaml'
    if (-not (Test-Path -LiteralPath $pubspecPath -PathType Leaf)) {
        return 'dev'
    }

    $match = Get-Content -LiteralPath $pubspecPath |
        Select-String -Pattern '^\s*version:\s*(\S+)\s*$' |
        Select-Object -First 1
    if ($match) {
        return $match.Matches[0].Groups[1].Value
    }
    return 'dev'
}

function Get-GitCommitHash {
    try {
        $commit = (& git -C $PSScriptRoot rev-parse --short=12 HEAD 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commit)) {
            return $commit
        }
    } catch {
    }
    return ''
}

function New-DartDefineArgs {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectPath,
        [Parameter(Mandatory = $true)][string] $BackendBaseUrl
    )

    $releaseDate = Get-Date -Format "yyyy-MM-dd'T'HH:mm:sszzz"
    return @(
        '--dart-define', "BACKEND_BASE_URL=$BackendBaseUrl",
        '--dart-define', "APP_VERSION=$(Get-FlutterAppVersion -ProjectPath $ProjectPath)",
        '--dart-define', "BUILD_RELEASE_DATE=$releaseDate",
        '--dart-define', "BUILD_COMMIT_HASH=$(Get-GitCommitHash)"
    )
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
        'run_portable.bat'
    )
}

function Write-PortableManifest {
    param(
        [Parameter(Mandatory = $true)][string] $PortableDir,
        [Parameter(Mandatory = $true)][string] $ZipPath
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
            "$PortableName/run_portable.bat",
            "$PortableName/portable-manifest.txt"
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

$ProjectPath = Get-FullPath -Path (Join-Path -Path $PSScriptRoot -ChildPath 'sync_windows_agent')
$OutputRoot = Get-FullPath -Path $PSScriptRoot
$PortableName = ''

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter is not installed or not available in PATH.'
}

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
Remove-OutputPath -Path $portableDir -OutputRoot $OutputRoot -Purpose 'to remove the old portable directory before build'
Remove-OutputPath -Path $zipPath -OutputRoot $OutputRoot -Purpose 'to remove the old zip archive before build'

Push-Location $ProjectPath
try {
    Invoke-NativeCommand -Description 'Running flutter pub get...' -Command { & flutter pub get }
    Write-Host "Portable backend URL: $BackendBaseUrl"
    $buildDartDefines = New-DartDefineArgs -ProjectPath $ProjectPath -BackendBaseUrl $BackendBaseUrl
    Invoke-NativeCommand -Description 'Building Windows release...' -Command { & flutter build windows --release @buildDartDefines }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Windows release build did not produce expected executable: $exePath"
}

New-Item -Path $portableDir -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath $releaseDir -Force |
    Copy-Item -Destination $portableDir -Recurse -Force

Copy-VCRuntimeDlls -Destination $portableDir -ProjectPath $ProjectPath

New-PortableLauncher -Destination $portableDir -ExeName $exeName
Write-PortableManifest -PortableDir $portableDir -ZipPath $zipPath
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

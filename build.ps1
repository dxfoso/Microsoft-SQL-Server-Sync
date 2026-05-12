param(
    [string] $ProjectPath = "$PSScriptRoot\sync_windows_agent",
    [string] $OutputRoot = "$PSScriptRoot",
    [string] $PortableName = "",
    [switch] $SkipPubGet,
    [switch] $Clean,
    [switch] $NoVCRuntime
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

function Get-DirectorySize {
    param([Parameter(Mandatory = $true)][string] $Path)

    $sum = Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
        Measure-Object -Property Length -Sum
    return [long] $sum.Sum
}

$ProjectPath = Get-FullPath -Path $ProjectPath
$OutputRoot = Get-FullPath -Path $OutputRoot

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

Push-Location $ProjectPath
try {
    if ($Clean) {
        Invoke-NativeCommand -Description 'Running flutter clean...' -Command { & flutter clean }
    }

    if (-not $SkipPubGet) {
        Invoke-NativeCommand -Description 'Running flutter pub get...' -Command { & flutter pub get }
    }

    Invoke-NativeCommand -Description 'Building Windows release...' -Command { & flutter build windows --release }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Windows release build did not produce expected executable: $exePath"
}

Remove-OutputPath -Path $portableDir -OutputRoot $OutputRoot -Purpose 'to remove the old portable directory'
Remove-OutputPath -Path $zipPath -OutputRoot $OutputRoot -Purpose 'to remove the old zip archive'

New-Item -Path $portableDir -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath $releaseDir -Force |
    Copy-Item -Destination $portableDir -Recurse -Force

if (-not $NoVCRuntime) {
    Copy-VCRuntimeDlls -Destination $portableDir -ProjectPath $ProjectPath
}

New-PortableLauncher -Destination $portableDir -ExeName $exeName

Write-Host "Creating zip archive..."
Compress-Archive -LiteralPath $portableDir -DestinationPath $zipPath -Force

$portableSize = Get-DirectorySize -Path $portableDir
$zipSize = (Get-Item -LiteralPath $zipPath).Length

Write-Host ''
Write-Host 'Portable Windows build complete.'
Write-Host "Folder: $portableDir"
Write-Host "Zip:    $zipPath"
Write-Host "EXE:    $(Join-Path -Path $portableDir -ChildPath $exeName)"
Write-Host ("Folder size: {0:N1} MB" -f ($portableSize / 1MB))
Write-Host ("Zip size:    {0:N1} MB" -f ($zipSize / 1MB))

Set-StrictMode -Version Latest

function Get-WindowsAgentVsInstallationPath {
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
        return $null
    }

    $vswherePath = Join-Path -Path $programFilesX86 -ChildPath 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
        return $null
    }

    $installationPath = (& $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $installationPath = @($installationPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]
    if ([string]::IsNullOrWhiteSpace($installationPath)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($installationPath.Trim())
}

function Import-WindowsAgentVisualStudioEnvironment {
    $installationPath = Get-WindowsAgentVsInstallationPath
    if ([string]::IsNullOrWhiteSpace($installationPath)) {
        throw 'Could not locate a Visual Studio installation with C++ tools. Install the Desktop development with C++ workload.'
    }

    $vsDevCmdPath = Join-Path -Path $installationPath -ChildPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $vsDevCmdPath -PathType Leaf)) {
        throw "Could not locate VsDevCmd.bat at: $vsDevCmdPath"
    }

    $envDump = & cmd.exe /s /c "`"$vsDevCmdPath`" -arch=x64 -host_arch=x64 >nul && set"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to import Visual Studio build environment from: $vsDevCmdPath"
    }

    foreach ($line in $envDump) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -lt 1) {
            continue
        }

        $name = $line.Substring(0, $separatorIndex)
        $value = $line.Substring($separatorIndex + 1)
        Set-Item -Path "Env:$name" -Value $value
    }

    $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($null -eq $clCommand) {
        throw 'Visual Studio environment was imported, but cl.exe is still unavailable.'
    }

    $compilerPath = $clCommand.Source
    Set-Item -Path Env:CC -Value $compilerPath
    Set-Item -Path Env:CXX -Value $compilerPath
    Set-Item -Path Env:CMAKE_C_COMPILER -Value $compilerPath
    Set-Item -Path Env:CMAKE_CXX_COMPILER -Value $compilerPath

    Write-Host "Using Visual Studio C++ toolchain from: $installationPath"
}

function Get-WindowsAgentFlutterAppVersion {
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

function Get-WindowsAgentGitCommitHash {
    param([Parameter(Mandatory = $true)][string] $RepoRoot)

    try {
        $commit = (& git -C $RepoRoot rev-parse --short=12 HEAD 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commit)) {
            return $commit
        }
    } catch {
    }

    return ''
}

function New-WindowsAgentDartDefineArgs {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectPath,
        [Parameter(Mandatory = $true)][string] $BackendBaseUrl,
        [Parameter(Mandatory = $true)][string] $RepoRoot
    )

    $releaseDate = Get-Date -Format "yyyy-MM-dd'T'HH:mm:sszzz"
    return @(
        '--dart-define', "BACKEND_BASE_URL=$BackendBaseUrl",
        '--dart-define', "APP_VERSION=$(Get-WindowsAgentFlutterAppVersion -ProjectPath $ProjectPath)",
        '--dart-define', "BUILD_RELEASE_DATE=$releaseDate",
        '--dart-define', "BUILD_COMMIT_HASH=$(Get-WindowsAgentGitCommitHash -RepoRoot $RepoRoot)"
    )
}

function Stop-WindowsAgentBuildProcesses {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $projectRoot = [System.IO.Path]::GetFullPath($ProjectPath)
    $buildRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64'))
    $trimChars = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $projectRootPrefix = $projectRoot.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    $buildRootPrefix = $buildRoot.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    $buildToolProcessNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('sync_windows_agent.exe', 'cmake.exe', 'msbuild.exe', 'ninja.exe', 'dart.exe', 'dartaotruntime.exe', 'dartvm.exe', 'flutter.exe', 'cmd.exe')) {
        [void] $buildToolProcessNames.Add($name)
    }

    $projectScopedProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not $buildToolProcessNames.Contains($_.Name)) {
                return $false
            }

            $executablePath = $_.ExecutablePath
            $commandLine = $_.CommandLine

            if (-not [string]::IsNullOrWhiteSpace($executablePath)) {
                $fullExecutablePath = [System.IO.Path]::GetFullPath($executablePath)
                if ($fullExecutablePath.StartsWith($buildRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }

            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                return $false
            }

            return $commandLine.IndexOf($projectRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $commandLine.IndexOf($buildRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })

    $candidateProcesses = [System.Collections.Generic.List[object]]::new()
    foreach ($process in $projectScopedProcesses) {
        [void] $candidateProcesses.Add($process)
    }

    if ($projectScopedProcesses.Count -gt 0) {
        foreach ($supportProcessName in @('mspdbsrv.exe', 'vctip.exe')) {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $supportProcessName } |
                ForEach-Object { [void] $candidateProcesses.Add($_) }
        }
    }

    foreach ($process in $candidateProcesses) {
        try {
            Write-Host "Stopping process locking Windows build artifacts: $($process.Name) [$($process.ProcessId)]"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        } catch {
            throw "Failed to stop process $($process.Name) [$($process.ProcessId)] before cleaning Windows build artifacts. $($_.Exception.Message)"
        }
    }
}

function Stop-WindowsAgentBuildSupportProcesses {
    $supportProcessNames = @('mspdbsrv.exe', 'vctip.exe')
    foreach ($supportProcessName in $supportProcessNames) {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $supportProcessName } |
            ForEach-Object {
                try {
                    Write-Host "Stopping Windows build support process: $($_.Name) [$($_.ProcessId)]"
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                } catch {
                    throw "Failed to stop Windows build support process $($_.Name) [$($_.ProcessId)]. $($_.Exception.Message)"
                }
            }
    }
}

function Get-WindowsAgentConflictingDevProcesses {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $projectRoot = [System.IO.Path]::GetFullPath($ProjectPath)
    $repoRoot = Split-Path -Path $projectRoot -Parent
    $debugExePath = [System.IO.Path]::GetFullPath((Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64\runner\Debug\sync_windows_agent.exe'))
    $trimChars = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $projectRootPrefix = $projectRoot.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    $runScriptPath = [System.IO.Path]::GetFullPath((Join-Path -Path $repoRoot -ChildPath 'run.ps1'))
    $clientScriptPath = [System.IO.Path]::GetFullPath((Join-Path -Path $repoRoot -ChildPath 'client.ps1'))

    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $directConflicts = @($allProcesses |
        Where-Object {
            if ($_.ProcessId -eq $PID) {
                return $false
            }

            $commandLine = $_.CommandLine
            $executablePath = $_.ExecutablePath

            if (-not [string]::IsNullOrWhiteSpace($executablePath)) {
                $fullExecutablePath = [System.IO.Path]::GetFullPath($executablePath)
                if ($fullExecutablePath.Equals($debugExePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }

            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                return $false
            }

            return $commandLine.IndexOf($projectRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $commandLine.IndexOf($runScriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $commandLine.IndexOf($clientScriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })

    $processById = @{}
    foreach ($process in $allProcesses) {
        $processById[$process.ProcessId] = $process
    }

    $selectedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($process in $directConflicts) {
        if ($selectedProcessIds.Add($process.ProcessId)) {
            $queue.Enqueue($process)
        }
    }

    while ($queue.Count -gt 0) {
        $process = $queue.Dequeue()
        if (-not $processById.ContainsKey($process.ParentProcessId)) {
            continue
        }

        $parentProcess = $processById[$process.ParentProcessId]
        if ($parentProcess.ProcessId -eq $PID) {
            continue
        }

        if ($selectedProcessIds.Add($parentProcess.ProcessId)) {
            $queue.Enqueue($parentProcess)
        }
    }

    return @(
        $selectedProcessIds |
            ForEach-Object { $processById[$_] } |
            Sort-Object ProcessId
    )
}

function Stop-WindowsAgentConflictingDevProcesses {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $conflictingProcesses = @(Get-WindowsAgentConflictingDevProcesses -ProjectPath $ProjectPath)
    foreach ($process in $conflictingProcesses) {
        try {
            Write-Host "Stopping conflicting Windows dev process: $($process.Name) [$($process.ProcessId)]"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        } catch {
            throw "Failed to stop conflicting Windows dev process $($process.Name) [$($process.ProcessId)]. $($_.Exception.Message)"
        }
    }
}

function Assert-NoWindowsAgentConflictingDevProcesses {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $conflictingProcesses = @(Get-WindowsAgentConflictingDevProcesses -ProjectPath $ProjectPath)
    if ($conflictingProcesses.Count -eq 0) {
        return
    }

    $processSummary = $conflictingProcesses |
        Sort-Object Name, ProcessId |
        ForEach-Object { "$($_.Name) [$($_.ProcessId)]" }

    throw "Portable build cannot run while the repo Windows desktop dev session is active. Stop run.ps1 or any flutter run windows session for sync_windows_agent, then retry. Active processes: $($processSummary -join ', ')"
}

function Remove-WindowsAgentBuildPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $attemptCount = 3
    for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq $attemptCount) {
                throw
            }

            if ($attempt -eq 1) {
                Stop-WindowsAgentBuildSupportProcesses
            }

            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
}

function Get-WindowsAgentLatestAotLibraryPath {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $flutterBuildPath = Join-Path -Path $ProjectPath -ChildPath '.dart_tool\flutter_build'
    if (-not (Test-Path -LiteralPath $flutterBuildPath -PathType Container)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $flutterBuildPath -Recurse -Filter 'app.so' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Restore-WindowsAgentAotLibrary {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $destinationPath = Join-Path -Path $ProjectPath -ChildPath 'build\windows\app.so'
    $latestAotLibrary = Get-WindowsAgentLatestAotLibraryPath -ProjectPath $ProjectPath
    if ($null -eq $latestAotLibrary) {
        return $false
    }

    $destinationDir = Split-Path -Path $destinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
        New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
    }

    Copy-Item -LiteralPath $latestAotLibrary.FullName -Destination $destinationPath -Force
    Write-Host "Restored missing Windows AOT library: $destinationPath"
    return $true
}

function Test-WindowsAgentReleaseInstallRecoveryNeeded {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $releaseExe = Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64\runner\Release\sync_windows_agent.exe'
    $cmakeInstallPath = Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64\cmake_install.cmake'
    $aotLibraryPath = Join-Path -Path $ProjectPath -ChildPath 'build\windows\app.so'

    return (
        (Test-Path -LiteralPath $releaseExe -PathType Leaf) -and
        (Test-Path -LiteralPath $cmakeInstallPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $aotLibraryPath -PathType Leaf)
    )
}

function Invoke-WindowsAgentReleaseInstall {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $cmakeInstallPath = Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64\cmake_install.cmake'
    if (-not (Test-Path -LiteralPath $cmakeInstallPath -PathType Leaf)) {
        throw "Missing CMake install script: $cmakeInstallPath"
    }

    $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
    $cmakeExe = if ($cmakeCommand) { $cmakeCommand.Source } else { $null }

    if ([string]::IsNullOrWhiteSpace($cmakeExe) -or -not (Test-Path -LiteralPath $cmakeExe -PathType Leaf)) {
        $candidatePaths = @(
            (Join-Path -Path ${env:ProgramFiles} -ChildPath 'Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'),
            (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe')
        )

        $cmakeExe = $candidatePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Select-Object -First 1
    }

    if ([string]::IsNullOrWhiteSpace($cmakeExe)) {
        throw 'Could not locate cmake.exe for the Windows release install step.'
    }

    & $cmakeExe -DBUILD_TYPE=Release -P $cmakeInstallPath
    if ($LASTEXITCODE -ne 0) {
        throw "CMake release install failed with exit code $LASTEXITCODE."
    }
}

function Remove-WindowsAgentBuildArtifacts {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $paths = @(
        (Join-Path -Path $ProjectPath -ChildPath 'build\windows\app.so'),
        (Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64'),
        (Join-Path -Path $ProjectPath -ChildPath 'windows\flutter\ephemeral')
    )

    Stop-WindowsAgentBuildProcesses -ProjectPath $ProjectPath

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        Write-Host "Removing stale Windows build artifacts: $path"
        Remove-WindowsAgentBuildPath -Path $path
    }
}

function Initialize-WindowsAgentBuildEnvironment {
    Import-WindowsAgentVisualStudioEnvironment
}

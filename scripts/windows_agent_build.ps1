Set-StrictMode -Version Latest

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

function Remove-WindowsAgentBuildArtifacts {
    param([Parameter(Mandatory = $true)][string] $ProjectPath)

    $paths = @(
        (Join-Path -Path $ProjectPath -ChildPath 'build\windows\x64'),
        (Join-Path -Path $ProjectPath -ChildPath 'windows\flutter\ephemeral')
    )

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        Write-Host "Removing stale Windows build artifacts: $path"
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

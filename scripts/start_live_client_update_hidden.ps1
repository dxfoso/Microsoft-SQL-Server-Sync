[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ClientName,
    [Parameter(Mandatory = $true)][string] $TargetVersion,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedCommit,
    [ValidateRange(30, 1800)][int] $WaitSeconds = 300,
    [string] $LogPrefix = 'client-update',
    [string] $SshAlias = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $AdminSecretName = 'sync-auto-scheduler'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$verifier = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'verify_live_client_update.py'))
foreach ($value in @($ClientName, $TargetVersion, $LogPrefix, $SshAlias, $Namespace, $AdminSecretName)) {
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('"') -or $value.Contains("`r") -or $value.Contains("`n")) {
        throw 'Client update launcher values must be non-empty single-line text without quote characters.'
    }
}
$python = (Get-Command python -ErrorAction Stop).Source
$safeLogPrefix = $LogPrefix -replace '[^A-Za-z0-9._-]', '_'
$stdoutPath = Join-Path $repoRoot "$safeLogPrefix.stdout.log"
$stderrPath = Join-Path $repoRoot "$safeLogPrefix.stderr.log"
$previousUser = [Environment]::GetEnvironmentVariable('SQL_SYNC_ADMIN_USERNAME', 'Process')
$previousPassword = [Environment]::GetEnvironmentVariable('SQL_SYNC_ADMIN_PASSWORD', 'Process')

try {
    $publicReady = $false
    $lastPublicError = ''
    for ($attempt = 1; $attempt -le 6; $attempt += 1) {
        try {
            $manifest = Invoke-RestMethod -Uri 'https://sync.velvet-leaf.com/client/latest.json' -Method Get -TimeoutSec 30
            if ([string]$manifest.version -ne $TargetVersion -or [string]$manifest.commit -ne $ExpectedCommit.Substring(0, 12)) {
                throw 'The public client manifest does not identify the requested release.'
            }
            $filesResponse = Invoke-WebRequest -Uri ([string]$manifest.filesManifestUrl) -Method Get -UseBasicParsing -TimeoutSec 30
            if ($filesResponse.StatusCode -eq 200 -and $filesResponse.RawContentLength -gt 0) {
                $publicReady = $true
                break
            }
            throw 'The public differential files manifest is not readable.'
        }
        catch {
            $lastPublicError = $_.Exception.Message
            if ($attempt -lt 6) { Start-Sleep -Seconds 5 }
        }
    }
    if (-not $publicReady) {
        throw "The public client update is not ready; no update was requested: $lastPublicError"
    }
    $secretLines = @(& ssh $SshAlias "kubectl get secret $AdminSecretName -n $Namespace -o json")
    if ($LASTEXITCODE -ne 0 -or $secretLines.Count -eq 0) {
        throw 'Unable to read the namespace administrator Secret.'
    }
    $secret = ($secretLines -join "`n") | ConvertFrom-Json
    $adminUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$secret.data.ADMIN_NAME))
    $adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$secret.data.ADMIN_PASSWORD))
    if ([string]::IsNullOrWhiteSpace($adminUser) -or [string]::IsNullOrWhiteSpace($adminPassword)) {
        throw 'The namespace administrator credential is incomplete.'
    }
    $env:SQL_SYNC_ADMIN_USERNAME = $adminUser
    $env:SQL_SYNC_ADMIN_PASSWORD = $adminPassword
    $arguments = '"{0}" "{1}" "{2}" --expect-commit "{3}" --wait-seconds {4}' -f `
        $verifier, $ClientName, $TargetVersion, $ExpectedCommit, $WaitSeconds
    $process = Start-Process `
        -FilePath $python `
        -ArgumentList $arguments `
        -WorkingDirectory $repoRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    [pscustomobject]@{
        Pid = $process.Id
        Stdout = $stdoutPath
        Stderr = $stderrPath
    } | ConvertTo-Json -Compress
}
finally {
    [Environment]::SetEnvironmentVariable('SQL_SYNC_ADMIN_USERNAME', $previousUser, 'Process')
    [Environment]::SetEnvironmentVariable('SQL_SYNC_ADMIN_PASSWORD', $previousPassword, 'Process')
    Remove-Variable adminPassword, adminUser, secret -ErrorAction SilentlyContinue
}

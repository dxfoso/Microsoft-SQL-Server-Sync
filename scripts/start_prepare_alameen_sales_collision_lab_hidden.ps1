[CmdletBinding()]
param(
    [string[]] $ClientName = @('alshallan2', 'velvet factory'),
    [string] $Database = 'AmnDb048_SyncLab',
    [ValidateRange(1, 100)][int] $MaxPasses = 100,
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $AdminSecretName = 'sync-auto-scheduler',
    [string] $LogPrefix = 'prepare-alameen-sales-collision-lab'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'prepare_alameen_sales_collision_lab.py'))

if ($ClientName.Count -eq 0) { throw 'At least one client name is required.' }
foreach ($value in @($ClientName) + @($Database, $SshTarget, $Namespace, $AdminSecretName, $LogPrefix)) {
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('"') -or $value.Contains("`r") -or $value.Contains("`n")) {
        throw 'Launcher values must be non-empty single-line text without quote characters.'
    }
}

$secretLines = @(& ssh $SshTarget "kubectl get secret $AdminSecretName -n $Namespace -o json")
if ($LASTEXITCODE -ne 0 -or $secretLines.Count -eq 0) {
    throw 'Unable to read the namespace administrator Secret.'
}
$secret = ($secretLines -join "`n") | ConvertFrom-Json
$adminUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$secret.data.ADMIN_NAME))
$adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$secret.data.ADMIN_PASSWORD))
if ([string]::IsNullOrWhiteSpace($adminUser) -or [string]::IsNullOrWhiteSpace($adminPassword)) {
    throw 'The namespace administrator credential is incomplete.'
}

$safeLogPrefix = $LogPrefix -replace '[^A-Za-z0-9._-]', '_'
$stdoutPath = Join-Path $repoRoot "$safeLogPrefix.stdout.log"
$stderrPath = Join-Path $repoRoot "$safeLogPrefix.stderr.log"
$python = (Get-Command python -ErrorAction Stop).Source
$clientArguments = @($ClientName | ForEach-Object { '--client "{0}"' -f $_ })
$arguments = '"{0}" {1} --database "{2}" --max-passes {3}' -f `
    $helper, ($clientArguments -join ' '), $Database, $MaxPasses
$previousUser = [Environment]::GetEnvironmentVariable('SQL_SYNC_ADMIN_USERNAME', 'Process')
$previousPassword = [Environment]::GetEnvironmentVariable('SQL_SYNC_ADMIN_PASSWORD', 'Process')

try {
    $env:SQL_SYNC_ADMIN_USERNAME = $adminUser
    $env:SQL_SYNC_ADMIN_PASSWORD = $adminPassword
    $process = Start-Process -FilePath $python -ArgumentList $arguments `
        -WorkingDirectory $repoRoot -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    [pscustomobject]@{
        Pid = $process.Id
        Stdout = $stdoutPath
        Stderr = $stderrPath
    } | ConvertTo-Json -Compress
}
finally {
    [Environment]::SetEnvironmentVariable('SQL_SYNC_ADMIN_USERNAME', $previousUser, 'Process')
    [Environment]::SetEnvironmentVariable('SQL_SYNC_ADMIN_PASSWORD', $previousPassword, 'Process')
}

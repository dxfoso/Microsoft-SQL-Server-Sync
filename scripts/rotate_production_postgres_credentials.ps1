[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $PostgresSecretName = 'sql-sync-postgres',
    [string] $BackendSecretName = 'sql-sync-backend',
    [string] $PostgresDeployment = 'sql-sync-postgres',
    [string] $BackendDeployment = 'sql-sync-back',
    [string[]] $CronJobs = @('sql-sync-auto-tick', 'sql-sync-history-maintenance'),
    [string] $HealthUrl = 'https://sync.velvet-leaf.com/admin/health',
    [string] $ExpectedCommit = '96dd9579fd3f17236aada1d6af600e5059c51994'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($value in @($Namespace, $PostgresSecretName, $BackendSecretName,
        $PostgresDeployment, $BackendDeployment) + $CronJobs) {
    if ($value -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
        throw "Invalid Kubernetes resource name: $value"
    }
}

function Get-SecretText {
    param([string] $SecretName, [string] $Key)
    $encoded = (& ssh $SshTarget kubectl get secret $SecretName -n $Namespace `
        -o "jsonpath={.data.$Key}").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) {
        throw "Unable to read required key $Key from Secret $SecretName."
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
}

function Set-SecretText {
    param([string] $SecretName, [string] $Key, [string] $Value)
    $patch = @{
        data = @{
            $Key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $result = $patch | & ssh $SshTarget `
        "kubectl patch secret $SecretName -n $Namespace --type=merge --patch-file=/dev/stdin"
    if ($LASTEXITCODE -ne 0) { throw "Unable to update Secret $SecretName." }
    return $result
}

function New-StrongPassword {
    $bytes = [byte[]]::new(36)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return "Aa9$([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', 'X').Replace('/', 'Y'))"
}

function Get-CronState {
    param([string] $Name)
    $raw = & ssh $SshTarget kubectl get cronjob $Name -n $Namespace -o json
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect CronJob $Name." }
    $cron = (($raw -join "`n") | ConvertFrom-Json)
    $activeProperty = $cron.status.PSObject.Properties['active']
    $activeCount = if ($null -eq $activeProperty) { 0 } else { @($cron.status.active).Count }
    return [pscustomobject]@{
        suspended = [bool]$cron.spec.suspend
        active = $activeCount
    }
}

function Set-CronSuspended {
    param([string] $Name, [bool] $Suspended)
    $patch = @{ spec = @{ suspend = $Suspended } } | ConvertTo-Json -Compress
    $result = $patch | & ssh $SshTarget `
        "kubectl patch cronjob $Name -n $Namespace --type=merge --patch-file=/dev/stdin"
    if ($LASTEXITCODE -ne 0) { throw "Unable to set CronJob $Name suspend=$Suspended." }
    return $result
}

function Set-DatabaseRolePassword {
    param([string] $Role, [string] $Database, [string] $Password)
    if ($Role -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
        $Database -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw 'The database URL contains an unsupported role or database identifier.'
    }
    $escapedPassword = $Password.Replace("'", "''")
    $sql = "ALTER ROLE `"$Role`" WITH PASSWORD '$escapedPassword';"
    $result = $sql | & ssh $SshTarget `
        "kubectl exec -i -n $Namespace deployment/$PostgresDeployment -- psql -v ON_ERROR_STOP=1 -U $Role -d $Database"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to update the PostgreSQL role password.' }
    return $result
}

function Restart-And-Wait {
    param([string] $Deployment)
    & ssh $SshTarget kubectl rollout restart deployment/$Deployment -n $Namespace | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to restart deployment/$Deployment." }
    & ssh $SshTarget kubectl rollout status deployment/$Deployment -n $Namespace --timeout=300s | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "deployment/$Deployment did not become Ready." }
}

$oldPassword = Get-SecretText -SecretName $PostgresSecretName -Key 'POSTGRES_PASSWORD'
$oldUrl = Get-SecretText -SecretName $BackendSecretName -Key 'TRU_POSTGRESQL_URL'
$urlBuilder = [UriBuilder]$oldUrl
$role = [Uri]::UnescapeDataString($urlBuilder.UserName)
$urlPassword = [Uri]::UnescapeDataString($urlBuilder.Password)
$database = $urlBuilder.Path.Trim('/')
if ($urlBuilder.Scheme -notin @('postgres', 'postgresql') -or
    [string]::IsNullOrWhiteSpace($role) -or
    [string]::IsNullOrWhiteSpace($database) -or
    $urlPassword -cne $oldPassword) {
    throw 'PostgreSQL Secret and backend URL failed the consistency preflight.'
}

$newPassword = New-StrongPassword
$newUrlBuilder = [UriBuilder]$oldUrl
$newUrlBuilder.Password = $newPassword
$newUrl = $newUrlBuilder.Uri.AbsoluteUri
$cronStates = @{}
$passwordChanged = $false
$postgresSecretChanged = $false
$backendSecretChanged = $false

try {
    foreach ($cronName in $CronJobs) {
        $cronStates[$cronName] = Get-CronState -Name $cronName
        Set-CronSuspended -Name $cronName -Suspended $true | Out-Null
    }
    foreach ($cronName in $CronJobs) {
        if ((Get-CronState -Name $cronName).active -ne 0) {
            throw "CronJob $cronName still has an active Job; no credential was changed."
        }
    }

    Set-DatabaseRolePassword -Role $role -Database $database -Password $newPassword | Out-Null
    $passwordChanged = $true
    Set-SecretText -SecretName $PostgresSecretName -Key 'POSTGRES_PASSWORD' -Value $newPassword | Out-Null
    $postgresSecretChanged = $true
    Set-SecretText -SecretName $BackendSecretName -Key 'TRU_POSTGRESQL_URL' -Value $newUrl | Out-Null
    $backendSecretChanged = $true

    Restart-And-Wait -Deployment $PostgresDeployment
    Restart-And-Wait -Deployment $BackendDeployment
    $health = Invoke-RestMethod -Method Get -Uri $HealthUrl -TimeoutSec 30
    if (-not [bool]$health.ready -or -not [bool]$health.db_available -or
        [int]$health.compile_errors -ne 0 -or
        [string]$health.build.git_commit -ne $ExpectedCommit) {
        throw 'Production health did not match the required ready database and immutable build state.'
    }
}
catch {
    $originalError = $_.Exception.Message
    $recoveryErrors = [Collections.Generic.List[string]]::new()
    if ($passwordChanged) {
        try { Set-DatabaseRolePassword -Role $role -Database $database -Password $oldPassword | Out-Null }
        catch { $recoveryErrors.Add('database role rollback failed') }
    }
    if ($postgresSecretChanged) {
        try { Set-SecretText -SecretName $PostgresSecretName -Key 'POSTGRES_PASSWORD' -Value $oldPassword | Out-Null }
        catch { $recoveryErrors.Add('PostgreSQL Secret rollback failed') }
    }
    if ($backendSecretChanged) {
        try { Set-SecretText -SecretName $BackendSecretName -Key 'TRU_POSTGRESQL_URL' -Value $oldUrl | Out-Null }
        catch { $recoveryErrors.Add('backend Secret rollback failed') }
    }
    if ($passwordChanged) {
        try { Restart-And-Wait -Deployment $PostgresDeployment }
        catch { $recoveryErrors.Add('PostgreSQL recovery rollout failed') }
        try { Restart-And-Wait -Deployment $BackendDeployment }
        catch { $recoveryErrors.Add('backend recovery rollout failed') }
    }
    foreach ($cronName in $cronStates.Keys) {
        try { Set-CronSuspended -Name $cronName -Suspended $cronStates[$cronName].suspended | Out-Null }
        catch { $recoveryErrors.Add("CronJob $cronName state restoration failed") }
    }
    if ($recoveryErrors.Count -gt 0) {
        throw "$originalError Recovery was incomplete: $($recoveryErrors -join '; ')."
    }
    throw $originalError
}

foreach ($cronName in $cronStates.Keys) {
    Set-CronSuspended -Name $cronName -Suspended $cronStates[$cronName].suspended | Out-Null
}

[pscustomobject]@{
    passwordRotated = $true
    postgresSecretUpdated = $true
    backendSecretUpdated = $true
    deploymentsReady = $true
    healthVerified = $true
    cronJobsRestored = $true
} | ConvertTo-Json -Compress

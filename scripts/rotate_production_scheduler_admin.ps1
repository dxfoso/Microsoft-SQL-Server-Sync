[CmdletBinding()]
param(
    [string] $BaseUrl = 'https://sync.velvet-leaf.com',
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $SecretName = 'sync-auto-scheduler',
    [string] $CronJobName = 'sql-sync-auto-tick'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($value in @($Namespace, $SecretName, $CronJobName)) {
    if ($value -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
        throw "Invalid Kubernetes resource name: $value"
    }
}

function Invoke-ControlPlaneFunction {
    param([string] $Name, [hashtable] $Arguments)
    $body = @{ name = $Name; args = $Arguments } | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-RestMethod -Method Post -Uri "$($BaseUrl.TrimEnd('/'))/call" `
        -ContentType 'application/json' -Body $body -TimeoutSec 60
    if ($response.status -eq 'failed') {
        $detail = [string]$response.error
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = [string]$response.message }
        throw "${Name}: $detail"
    }
    if ($response.status -eq 'success' -and $null -ne $response.value) {
        return $response.value
    }
    return $response
}

function Get-SecretText {
    param([string] $Key)
    $encoded = (& ssh $SshTarget kubectl get secret $SecretName -n $Namespace `
        -o "jsonpath={.data.$Key}").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encoded)) {
        throw "Unable to read required scheduler secret key $Key."
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
}

function Set-SchedulerSecret {
    param([string] $AdminName, [string] $AdminPassword)
    $manifest = @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{ name = $SecretName; namespace = $Namespace }
        type = 'Opaque'
        data = @{
            ADMIN_NAME = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AdminName))
            ADMIN_PASSWORD = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AdminPassword))
        }
    } | ConvertTo-Json -Depth 8 -Compress
    $result = $manifest | & ssh $SshTarget "kubectl apply -n $Namespace -f -"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to update the scheduler credential secret.' }
    return $result
}

function Set-SchedulerSuspended {
    param([bool] $Suspended)
    $patch = @{ spec = @{ suspend = $Suspended } } | ConvertTo-Json -Compress
    $result = $patch | & ssh $SshTarget `
        "kubectl patch cronjob $CronJobName -n $Namespace --type=merge --patch-file=/dev/stdin"
    if ($LASTEXITCODE -ne 0) { throw "Unable to set scheduler suspend=$Suspended." }
    return $result
}

function New-StrongPassword {
    $bytes = [byte[]]::new(36)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "Aa9!$token"
}

$oldName = Get-SecretText -Key 'ADMIN_NAME'
$oldPassword = Get-SecretText -Key 'ADMIN_PASSWORD'
$newPassword = New-StrongPassword
$schedulerSuspended = $false
$secretChanged = $false
$passwordChanged = $false

try {
    Set-SchedulerSuspended -Suspended $true | Out-Null
    $schedulerSuspended = $true

    $login = Invoke-ControlPlaneFunction 'auth_login' @{
        name = $oldName
        password = $oldPassword
        app = 'credential-rotation'
    }
    $token = [string]$login.token
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Administrator login returned no token.' }
    $listing = Invoke-ControlPlaneFunction 'users_list' @{ token = $token }
    $admin = @($listing.users | Where-Object {
        [string]$_.role -eq 'admin' -and [string]$_.username -eq $oldName.ToLowerInvariant()
    }) | Select-Object -First 1
    if ($null -eq $admin) { throw 'The scheduler credential does not identify an administrator.' }

    Set-SchedulerSecret -AdminName $oldName -AdminPassword $newPassword | Out-Null
    $secretChanged = $true
    Invoke-ControlPlaneFunction 'user_reset_password' @{
        userId = [string]$admin.id
        password = $newPassword
        token = $token
    } | Out-Null
    $passwordChanged = $true

    $verification = Invoke-ControlPlaneFunction 'auth_login' @{
        name = $oldName
        password = $newPassword
        app = 'credential-rotation-verification'
    }
    $verificationToken = [string]$verification.token
    if ([string]::IsNullOrWhiteSpace($verificationToken)) {
        throw 'Rotated administrator login returned no token.'
    }
    Invoke-ControlPlaneFunction 'auth_logout' @{ token = $verificationToken } | Out-Null
    Set-SchedulerSuspended -Suspended $false | Out-Null
    $schedulerSuspended = $false

    [pscustomobject]@{
        passwordRotated = $true
        sessionsRevoked = $true
        schedulerSecretUpdated = $true
        schedulerResumed = $true
    } | ConvertTo-Json -Compress
}
catch {
    if ($secretChanged -and -not $passwordChanged) {
        Set-SchedulerSecret -AdminName $oldName -AdminPassword $oldPassword | Out-Null
    }
    if ($schedulerSuspended -and -not $passwordChanged) {
        Set-SchedulerSuspended -Suspended $false | Out-Null
    }
    throw
}
finally {
    $oldPassword = $null
    $newPassword = $null
}

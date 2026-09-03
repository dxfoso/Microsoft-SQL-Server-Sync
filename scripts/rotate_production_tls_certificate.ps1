[CmdletBinding()]
param(
    [string] $SshTarget = 'velvet-leaf-1',
    [string] $Namespace = 'velvet-sql-server-sync',
    [string] $CertificateName = 'sql-sync-frontend-tls',
    [string] $LegacyCertificateName = 'sync-velvet-leaf-com-letsencrypt-tls',
    [string] $SecretName = 'sync-velvet-leaf-com-letsencrypt-tls',
    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($value in @($Namespace, $CertificateName, $LegacyCertificateName, $SecretName)) {
    if ($value -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') {
        throw "Invalid Kubernetes resource name: $value"
    }
}

function Get-CertificateRows {
    $raw = & ssh $SshTarget kubectl get certificates -n $Namespace -o json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read Certificate resources.' }
    return @(($raw -join "`n" | ConvertFrom-Json).items)
}

$owners = @(Get-CertificateRows | Where-Object { [string]$_.spec.secretName -eq $SecretName })
$expected = @($owners | Where-Object { [string]$_.metadata.name -eq $CertificateName })
$unexpected = @($owners | Where-Object {
    [string]$_.metadata.name -ne $CertificateName -and
    [string]$_.metadata.name -ne $LegacyCertificateName
})
if ($expected.Count -ne 1 -or $unexpected.Count -ne 0) {
    throw "Refusing TLS rotation: expected one $CertificateName owner and no unknown owner for $SecretName."
}
$ready = @( $expected[0].status.conditions | Where-Object {
    [string]$_.type -eq 'Ready' -and [string]$_.status -eq 'True'
})
if ($ready.Count -ne 1) { throw "Refusing TLS rotation: $CertificateName is not Ready." }
$oldRevision = [int]$expected[0].status.revision
$oldSecretUid = (& ssh $SshTarget kubectl get secret $SecretName -n $Namespace `
    -o 'jsonpath={.metadata.uid}').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($oldSecretUid)) {
    throw "Unable to resolve the current TLS Secret UID for $SecretName."
}

$legacy = @($owners | Where-Object { [string]$_.metadata.name -eq $LegacyCertificateName })
if ($legacy.Count -gt 1) { throw 'Refusing TLS rotation: duplicate legacy Certificate objects were returned.' }
if ($legacy.Count -eq 1) {
    & ssh $SshTarget kubectl delete certificate $LegacyCertificateName -n $Namespace
    if ($LASTEXITCODE -ne 0) { throw 'Unable to delete the exact legacy Certificate owner.' }
}

& ssh $SshTarget kubectl delete secret $SecretName -n $Namespace
if ($LASTEXITCODE -ne 0) { throw 'Unable to delete the exposed TLS Secret for reissuance.' }

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 5
    $newSecretUid = (& ssh $SshTarget kubectl get secret $SecretName -n $Namespace `
        --ignore-not-found -o 'jsonpath={.metadata.uid}').Trim()
    $certificateRows = @(Get-CertificateRows)
    $current = @($certificateRows | Where-Object { [string]$_.metadata.name -eq $CertificateName })
    $currentReady = @($current.status.conditions | Where-Object {
        [string]$_.type -eq 'Ready' -and [string]$_.status -eq 'True'
    })
    $newRevision = if ($current.Count -eq 1) { [int]$current[0].status.revision } else { 0 }
    if (-not [string]::IsNullOrWhiteSpace($newSecretUid) -and
        $newSecretUid -ne $oldSecretUid -and
        $currentReady.Count -eq 1 -and
        $newRevision -gt $oldRevision) {
        [pscustomobject]@{
            tlsSecretReissued = $true
            legacyCertificateRemoved = $legacy.Count -eq 1
            certificateReady = $true
            revisionAdvanced = $true
        } | ConvertTo-Json -Compress
        exit 0
    }
} while ([DateTime]::UtcNow -lt $deadline)

throw "TLS Secret was not reissued as a new Ready revision within $TimeoutSeconds seconds."

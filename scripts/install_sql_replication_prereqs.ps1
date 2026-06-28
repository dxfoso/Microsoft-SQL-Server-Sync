param(
    [string] $InstanceName = 'MSSQLSERVER',
    [string] $SetupPath = 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\SQL2022\setup.exe',
    [switch] $NoRestartAgent
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-CheckedNative {
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

function Get-AgentServiceName {
    param([Parameter(Mandatory = $true)][string] $SqlInstanceName)

    if ($SqlInstanceName -eq 'MSSQLSERVER') {
        return 'SQLSERVERAGENT'
    }

    return "SQLAgent`$$SqlInstanceName"
}

function Get-SqlSetupRegistryPath {
    param([Parameter(Mandatory = $true)][string] $SqlInstanceName)

    if ($SqlInstanceName -eq 'MSSQLSERVER') {
        return 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\Setup'
    }

    return "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.$SqlInstanceName\Setup"
}

function Get-SqlInstanceSetupInfo {
    param([Parameter(Mandatory = $true)][string] $SqlInstanceName)

    $registryPath = Get-SqlSetupRegistryPath -SqlInstanceName $SqlInstanceName
    if (-not (Test-Path -LiteralPath $registryPath)) {
        throw "SQL Server setup registry path not found for instance ${SqlInstanceName}: $registryPath"
    }

    $setup = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
    $sourcePathProperty = $setup.PSObject.Properties['SourcePath']
    $sourcePath = ''
    if ($null -ne $sourcePathProperty -and $null -ne $sourcePathProperty.Value) {
        $sourcePath = [string]$sourcePathProperty.Value
    }

    return [pscustomobject]@{
        RegistryPath = $registryPath
        Edition = [string]$setup.Edition
        Version = [string]$setup.Version
        PatchLevel = [string]$setup.PatchLevel
        SourcePath = $sourcePath
    }
}

function Resolve-ExistingSetupPath {
    param([Parameter(Mandatory = $true)][string[]] $Candidates)

    foreach ($candidate in $Candidates) {
        $trimmed = $candidate.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if (Test-Path -LiteralPath $trimmed -PathType Leaf) {
            return $trimmed
        }
    }

    return $null
}

function Resolve-SetupPathForInstance {
    param(
        [Parameter(Mandatory = $true)][string] $SqlInstanceName,
        [Parameter(Mandatory = $true)][string] $RequestedSetupPath
    )

    $setupInfo = Get-SqlInstanceSetupInfo -SqlInstanceName $SqlInstanceName
    $sourcePath = $setupInfo.SourcePath.Trim()
    $resolvedSourceSetup = $null
    if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
        $resolvedSourceSetup = Resolve-ExistingSetupPath -Candidates @(
            (Join-Path -Path $sourcePath -ChildPath 'setup.exe'),
            $sourcePath
        )
    }

    $requestedExists = Test-Path -LiteralPath $RequestedSetupPath -PathType Leaf
    if ($requestedExists -and $resolvedSourceSetup -and
        -not $RequestedSetupPath.Equals($resolvedSourceSetup, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Using SQL Server SourcePath setup instead of the requested bootstrap path because the installed instance reports source media at $resolvedSourceSetup."
        return [pscustomobject]@{
            SetupInfo = $setupInfo
            SetupPath = $resolvedSourceSetup
            Source = 'registry-sourcepath'
        }
    }

    if ($requestedExists -and -not [string]::IsNullOrWhiteSpace($sourcePath)) {
        return [pscustomobject]@{
            SetupInfo = $setupInfo
            SetupPath = $RequestedSetupPath
            Source = 'requested'
        }
    }

    if ($resolvedSourceSetup) {
        return [pscustomobject]@{
            SetupInfo = $setupInfo
            SetupPath = $resolvedSourceSetup
            Source = 'registry-sourcepath'
        }
    }

    if ($requestedExists -and [string]::IsNullOrWhiteSpace($sourcePath)) {
        return [pscustomobject]@{
            SetupInfo = $setupInfo
            SetupPath = $RequestedSetupPath
            Source = 'requested'
        }
    }

    throw "SQL Server setup.exe not found. Requested path: $RequestedSetupPath"
}

function Confirm-ReplicationInstalled {
    param([Parameter(Mandatory = $true)][string] $SqlInstanceName)

    Invoke-CheckedNative -Description "Verifying replication components on instance $SqlInstanceName..." -Command {
        & sqlcmd -S $env:COMPUTERNAME -d master -Q 'exec sys.sp_MS_replication_installed;'
    }
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw 'sqlcmd is required on PATH to verify replication installation.'
}

$resolvedSetup = Resolve-SetupPathForInstance -SqlInstanceName $InstanceName -RequestedSetupPath $SetupPath
$SetupPath = $resolvedSetup.SetupPath
$setupInfo = $resolvedSetup.SetupInfo

if (-not (Test-IsAdministrator)) {
    $arguments = @(
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-InstanceName', ('"{0}"' -f $InstanceName),
        '-SetupPath', ('"{0}"' -f $SetupPath)
    )
    if ($NoRestartAgent) {
        $arguments += '-NoRestartAgent'
    }

    Write-Host 'Administrator rights are required. Relaunching with UAC prompt...'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs | Out-Null
    return
}

$agentServiceName = Get-AgentServiceName -SqlInstanceName $InstanceName

Write-Host "Detected SQL instance edition: $($setupInfo.Edition)"
Write-Host "Using setup path ($($resolvedSetup.Source)): $SetupPath"

Invoke-CheckedNative -Description "Installing SQL Server replication feature for instance $InstanceName..." -Command {
    & $SetupPath /Q /IACCEPTSQLSERVERLICENSETERMS /ACTION=Install /FEATURES=Replication /INSTANCENAME=$InstanceName /INDICATEPROGRESS /UpdateEnabled=False
}

if (-not $NoRestartAgent) {
    Write-Host "Ensuring SQL Agent service $agentServiceName is running..."
    Start-Service -Name $agentServiceName -ErrorAction Stop
}

$agentService = Get-Service -Name $agentServiceName -ErrorAction Stop
$agentService | Select-Object Status, Name, DisplayName | Format-Table -AutoSize

Confirm-ReplicationInstalled -SqlInstanceName $InstanceName

Write-Host ''
Write-Host 'Replication prerequisites are installed and verified.'

param(
    [Parameter(Mandatory = $true)]
    [string] $RequestPath
)

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'SqlBulkStage.cs'
Add-Type -AssemblyName System.Data
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path $sourcePath -ReferencedAssemblies @('System.Data.dll', 'System.Web.Extensions.dll', 'System.Xml.dll')
$copiedRows = [SqlSync.BulkStageLoader]::Load($RequestPath)
Write-Output "__SQL_SYNC_BULK_ROWS__=$copiedRows"

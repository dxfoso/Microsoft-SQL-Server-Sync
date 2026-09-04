[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $StdoutPath,
    [Parameter(Mandatory = $true)]
    [string] $StderrPath,
    [int] $ProcessId = 0,
    [ValidateRange(1, 500)]
    [int] $Tail = 40
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-PlainTail {
    param([string] $Path, [int] $Count)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    # Joining forces FileInfo/provider-extended pipeline objects into plain text
    # before JSON serialization, preventing unrelated provider metadata leakage.
    return [string]((Get-Content -LiteralPath $Path -Tail $Count) -join "`n")
}

$running = $false
if ($ProcessId -gt 0) {
    $running = $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

[pscustomobject]@{
    running = $running
    stdout = Read-PlainTail -Path $StdoutPath -Count $Tail
    stderr = Read-PlainTail -Path $StderrPath -Count $Tail
} | ConvertTo-Json -Compress

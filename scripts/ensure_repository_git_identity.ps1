[CmdletBinding()]
param([string] $Repository = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}
$Repository = [IO.Path]::GetFullPath($Repository)
& git -C $Repository rev-parse --git-dir *> $null
if ($LASTEXITCODE -ne 0) { throw "Not a Git repository: $Repository" }

$name = (@(& git -C $Repository config --local user.name) -join '').Trim()
$email = (@(& git -C $Repository config --local user.email) -join '').Trim()
if ([string]::IsNullOrWhiteSpace($name)) {
    $name = (@(& git -C $Repository log -1 --format=%an) -join '').Trim()
}
if ([string]::IsNullOrWhiteSpace($email)) {
    $email = (@(& git -C $Repository log -1 --format=%ae) -join '').Trim()
}
if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email)) {
    throw 'No repository-local identity or existing commit author is available.'
}

& git -C $Repository config --local user.name $name
if ($LASTEXITCODE -ne 0) { throw 'Failed to set repository-local user.name.' }
& git -C $Repository config --local user.email $email
if ($LASTEXITCODE -ne 0) { throw 'Failed to set repository-local user.email.' }

[pscustomobject]@{ repository = $Repository; name = $name; email = $email } |
    ConvertTo-Json -Compress

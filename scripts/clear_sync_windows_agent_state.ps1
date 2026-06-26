$ErrorActionPreference = "Stop"

$processName = "sync_windows_agent"
$startupShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\SQL Sync Agent.lnk"
$stateDir = Join-Path $env:APPDATA "Microsoft-SQL-Server-Sync"

Write-Host "Stopping SQL Sync Agent processes..."
$processes = Get-Process $processName -ErrorAction SilentlyContinue
if ($processes) {
    $processes | Stop-Process -Force
    Start-Sleep -Seconds 2
} else {
    Write-Host "No running sync agent process found."
}

Write-Host "Removing startup shortcut..."
if (Test-Path -LiteralPath $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
} else {
    Write-Host "Startup shortcut not found."
}

Write-Host "Removing saved client state..."
if (Test-Path -LiteralPath $stateDir) {
    Remove-Item -LiteralPath $stateDir -Recurse -Force
} else {
    Write-Host "Saved state directory not found."
}

Write-Host "Checking for remaining agent processes..."
$remaining = Get-Process $processName -ErrorAction SilentlyContinue
if ($remaining) {
    Write-Warning "One or more sync agent processes are still running."
    $remaining | Select-Object Id, ProcessName, StartTime | Format-Table -AutoSize
    exit 1
}

Write-Host ""
Write-Host "Cleanup complete."
Write-Host "Next steps:"
Write-Host "1. Reboot the machine."
Write-Host "2. Start the client once from the latest build."

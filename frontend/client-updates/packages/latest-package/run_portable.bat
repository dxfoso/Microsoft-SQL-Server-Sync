@echo off
setlocal

set "APP_DIR=%~dp0"
set "SUPERVISOR=%APP_DIR%sync_windows_agent_supervisor.ps1"
set "SUPERVISOR_LOG=%APP_DIR%sync_windows_agent_supervisor.log"
set "REQUEST_LOG=%APP_DIR%sync_windows_agent_update_requests.log"
set "STARTUP_LOG=%APP_DIR%sync_windows_agent_startup.log"

if not exist "%SUPERVISOR%" (
  echo Missing supervisor: %SUPERVISOR%
  exit /b 1
)

echo Starting independent SQL Sync Agent supervisor.
echo Supervisor log: %SUPERVISOR_LOG%
echo Update request log: %REQUEST_LOG%
echo App startup log: %STARTUP_LOG%
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SUPERVISOR%" %*
exit /b 0

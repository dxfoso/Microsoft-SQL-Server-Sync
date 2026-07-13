@echo off
setlocal

set "APP_DIR=%~dp0"
set "APP_EXE=%APP_DIR%sync_windows_agent.exe"
set "LOG_FILE=%APP_DIR%portable.log"
set "STARTUP_LOG=%APP_DIR%sync_windows_agent_startup.log"

if not exist "%APP_EXE%" (
  echo Missing executable: %APP_EXE%
  exit /b 1
)

echo Starting portable app: %APP_EXE%
echo Writing console output to: %LOG_FILE%
echo Writing startup trace to: %STARTUP_LOG%
echo.

"%APP_EXE%" %* > "%LOG_FILE%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo Portable app exited with code %EXIT_CODE%.
echo Console output: %LOG_FILE%
echo Startup trace: %STARTUP_LOG%
exit /b %EXIT_CODE%

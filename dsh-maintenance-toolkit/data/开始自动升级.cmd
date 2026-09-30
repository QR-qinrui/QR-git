@echo off
rem Auto-upgrade the bundled DSH runtime: waits for the launcher window to close,
rem then runs the verified upgrade script (backup / assertions / rollback / restart).
rem Extra arguments are forwarded to watch-and-upgrade.ps1 (e.g. -DryRun, -WaitMinutes 10).
cd /d "%~dp0"
set "WATCH=%~dp0tools\watch-and-upgrade.ps1"
if not exist "%WATCH%" set "WATCH=%~dp0..\tools\watch-and-upgrade.ps1"
echo ============================================================
echo   DeepSeek Harness - automatic runtime upgrade
echo ============================================================
echo.
echo   This window will WAIT until the running Harness server is closed,
echo   then it performs the upgrade automatically and restarts the launcher.
echo.
echo   Step 1: press any key here to start waiting
echo   Step 2: close the running launcher window (the one serving the Web UI)
echo.
pause >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%WATCH%" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo Done. The launcher should be up again.) else (echo Not upgraded. Exit code %RC%)
pause

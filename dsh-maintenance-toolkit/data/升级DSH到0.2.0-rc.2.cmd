@echo off
rem One-shot upgrade of the bundled DSH runtime: 0.1.7-rc.2 -> 0.2.0-rc.2
rem   double-click            = run the upgrade (host must be stopped)
rem   add  -DryRun            = print the plan and preflight only, change nothing
rem   add  -Rollback          = restore the previous runtime and profile files
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0升级DSH到0.2.0-rc.2.ps1" %*
echo.
pause

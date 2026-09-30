@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0f12-audit-repair.ps1" %*
if errorlevel 1 pause

@echo off
rem DeepSeek Harness 独立深度维护工具 - 双击引导
rem 用本文件双击运行 maintain.ps1，避免 .ps1 被记事本打开。
chcp 65001 >nul
set "SCRIPT=%~dp0maintain.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
if errorlevel 1 pause

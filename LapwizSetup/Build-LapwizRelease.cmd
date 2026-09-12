@echo off
title Build Lapwiz Setup Release
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-LapwizRelease.ps1"
if errorlevel 1 (
  echo BUILD ECHEC
  pause
  exit /b 1
)
echo.
pause

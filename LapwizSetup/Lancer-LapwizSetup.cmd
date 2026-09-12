@echo off
title Lapwiz Setup
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-LapwizSetup.ps1"
if errorlevel 1 pause

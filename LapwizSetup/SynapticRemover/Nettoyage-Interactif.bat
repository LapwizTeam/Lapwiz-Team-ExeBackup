@echo off
setlocal EnableExtensions EnableDelayedExpansion
title SynapticRemover - Mode interactif
color 0A
mode con cols=100 lines=40
chcp 65001 >nul

:: Mode manuel : choix langue, scan, redemarrage
set "ROOT=%~dp0"
set "MOTEUR=%ROOT%tools\Moteur-Nettoyage.ps1"

net session >nul 2>&1
if errorlevel 1 (
    color 0C
    echo.
    echo  [x] Droits Administrateur requis
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Choix de la langue (FR / EN / AR)
call "%ROOT%tools\Selectionner-Langue.bat"
if not defined LANG set "LANG=fr"

powershell -NoProfile -ExecutionPolicy Bypass -File "%MOTEUR%" -Lang !LANG! -Interactive
set "ERR=!errorlevel!"
if not "!ERR!"=="0" (
    color 0C
    echo.
    echo  [x] Code de sortie: !ERR!
    pause
)
exit /b !ERR!

@echo off
setlocal EnableExtensions EnableDelayedExpansion
title SynapticRemover - Nettoyage automatique
color 0A
mode con cols=100 lines=40
chcp 65001 >nul

:: Nettoyage automatique complet (tous volumes, sans redemarrage)
set "ROOT=%~dp0"
set "MOTEUR=%ROOT%tools\Moteur-Nettoyage.ps1"

net session >nul 2>&1
if errorlevel 1 (
    color 0C
    echo.
    echo  [x] Droits Administrateur requis
    echo  Elevation en cours...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Choix de la langue (FR / EN / AR)
call "%ROOT%tools\Selectionner-Langue.bat"
if not defined LANG set "LANG=fr"

echo.
echo  [i] Nettoyage AUTOMATIQUE - caches, volumes, reparation EXE/XLSM
echo  [i] Langue=!LANG!  ^|  Rapports dans reports\  (max 5)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%MOTEUR%" -Lang !LANG! -ScanMode AllVolumes
set "ERR=!errorlevel!"
if not "!ERR!"=="0" (
    color 0C
    echo.
    echo  [x] Code de sortie: !ERR!
    timeout /t 12 >nul
)
exit /b !ERR!

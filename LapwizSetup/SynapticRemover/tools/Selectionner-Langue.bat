@echo off
:: Selection langue FR/EN/AR — a appeler avec: call "%ROOT%tools\Selectionner-Langue.bat"
:: Resultat: variable LANG = fr|en|ar (visible chez l'appelant)

set "SR_LANG_FILE=%TEMP%\synapticremover_lang.txt"
set "SR_LANG_PS=%~dp0Choix-Langue.ps1"

if not exist "%SR_LANG_PS%" (
    set "LANG=fr"
    goto :eof
)

del "%SR_LANG_FILE%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%SR_LANG_PS%" -OutFile "%SR_LANG_FILE%"
set "LANG=fr"
if exist "%SR_LANG_FILE%" (
    set /p LANG=<"%SR_LANG_FILE%"
)
if /I not "%LANG%"=="fr" if /I not "%LANG%"=="en" if /I not "%LANG%"=="ar" set "LANG=fr"
goto :eof

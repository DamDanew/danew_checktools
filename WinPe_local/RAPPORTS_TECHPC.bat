@echo off
setlocal

:: Detecte la lettre de lecteur de la cle USB (dossier du bat)
set "USB_ROOT=%~dp0"
set "USB_DRIVE=%~d0"

echo ============================================
echo  DANEW SAV - Rapports PC Technicien
echo ============================================
echo.
echo Cle USB detectee : %USB_DRIVE%
echo Dossier rapports  : %USB_ROOT%reports
echo.

:: Verifier que les scripts existent
if not exist "%USB_ROOT%scripts\DanewCheckTool.CLI.ps1" (
    echo ERREUR : DanewCheckTool.CLI.ps1 introuvable.
    echo Verifiez que la cle USB est correctement preparee depuis WinPE.
    pause
    exit /b 1
)

:: Verifier qu'il y a des artefacts JSON (preuve d'analyse WinPE)
if not exist "%USB_ROOT%reports\*.json" (
    echo ATTENTION : Aucun artefact JSON trouve dans le dossier reports.
    echo Lancez d'abord une analyse depuis WinPE sur le PC en panne.
    pause
    exit /b 1
)

echo Generation des rapports HTML depuis les artefacts WinPE...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%USB_ROOT%scripts\DanewCheckTool.CLI.ps1" -Command generate-html-reports -RootPath "%USB_DRIVE%" -Open

if %ERRORLEVEL% neq 0 (
    echo.
    echo La generation a rencontre une erreur. Verifiez les messages ci-dessus.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo Termine. Si le navigateur ne s'est pas ouvert automatiquement :
echo   %USB_ROOT%reports\REPORTS_INDEX.html
echo.
pause
endlocal

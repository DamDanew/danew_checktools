@echo off
setlocal

set DANEW_REPORTS=
if defined DANEW_ROOT if exist "%DANEW_ROOT%\reports" set DANEW_REPORTS=%DANEW_ROOT%\reports
if not defined DANEW_REPORTS if exist E:\reports set DANEW_REPORTS=E:\reports
if not defined DANEW_REPORTS if exist D:\reports set DANEW_REPORTS=D:\reports

set DANEW_MEDIA_ROOT=
if defined DANEW_ROOT set DANEW_MEDIA_ROOT=%DANEW_ROOT%
if not defined DANEW_MEDIA_ROOT if defined DANEW_REPORTS for %%R in ("%DANEW_REPORTS%\..") do set DANEW_MEDIA_ROOT=%%~fR

set DANEW_BROWSER=
if defined DANEW_MEDIA_ROOT if exist "%DANEW_MEDIA_ROOT%\tools\browser\chrome.exe" set DANEW_BROWSER=%DANEW_MEDIA_ROOT%\tools\browser\chrome.exe
if not defined DANEW_BROWSER if defined DANEW_MEDIA_ROOT if exist "%DANEW_MEDIA_ROOT%\tools\browser\chromium.exe" set DANEW_BROWSER=%DANEW_MEDIA_ROOT%\tools\browser\chromium.exe
if not defined DANEW_BROWSER if defined DANEW_MEDIA_ROOT if exist "%DANEW_MEDIA_ROOT%\tools\browser\msedge.exe" set DANEW_BROWSER=%DANEW_MEDIA_ROOT%\tools\browser\msedge.exe
if not defined DANEW_BROWSER if exist E:\tools\browser\chrome.exe set DANEW_BROWSER=E:\tools\browser\chrome.exe
if not defined DANEW_BROWSER if exist E:\tools\browser\chromium.exe set DANEW_BROWSER=E:\tools\browser\chromium.exe
if not defined DANEW_BROWSER if exist "X:\Program Files\Google\Chrome\Application\chrome.exe" set DANEW_BROWSER=X:\Program Files\Google\Chrome\Application\chrome.exe
if not defined DANEW_BROWSER if exist "X:\Program Files\Microsoft\Edge\Application\msedge.exe" set DANEW_BROWSER=X:\Program Files\Microsoft\Edge\Application\msedge.exe
if not defined DANEW_BROWSER if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set DANEW_BROWSER=%ProgramFiles%\Google\Chrome\Application\chrome.exe
if not defined DANEW_BROWSER if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set DANEW_BROWSER=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe
if not defined DANEW_BROWSER if exist "%ProgramFiles%\Internet Explorer\iexplore.exe" set DANEW_BROWSER=%ProgramFiles%\Internet Explorer\iexplore.exe

if defined DANEW_BROWSER (
    assoc .html=htmlfile >nul 2>nul
    ftype htmlfile="%DANEW_BROWSER%" "%%1" >nul 2>nul
    echo [DANEW] HTML association set to: %DANEW_BROWSER%
) else (
    echo [DANEW] Navigateur HTML non disponible. Consultez les rapports TXT/CSV dans le dossier reports.
)

if not "%~1"=="/quiet" (
    if defined DANEW_REPORTS (
        echo [DANEW] Reports path detected: %DANEW_REPORTS%
    ) else (
        echo [DANEW] Reports path not found.
    )
)

endlocal

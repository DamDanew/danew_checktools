@echo off
setlocal

set DANEW_REPORTS=
if defined DANEW_ROOT if exist "%DANEW_ROOT%\reports" set DANEW_REPORTS=%DANEW_ROOT%\reports
if not defined DANEW_REPORTS if exist E:\reports set DANEW_REPORTS=E:\reports
if not defined DANEW_REPORTS if exist D:\reports set DANEW_REPORTS=D:\reports

set DANEW_MEDIA_ROOT=
if defined DANEW_ROOT set DANEW_MEDIA_ROOT=%DANEW_ROOT%
if not defined DANEW_MEDIA_ROOT if defined DANEW_REPORTS for %%R in ("%DANEW_REPORTS%\..") do set DANEW_MEDIA_ROOT=%%~fR

if not defined DANEW_REPORTS (
    echo [DANEW] Reports root not found.
    exit /b 1
)

set DANEW_INDEX=%DANEW_REPORTS%\REPORTS_INDEX.html
if not exist "%DANEW_INDEX%" set DANEW_INDEX=%DANEW_REPORTS%\reports-index.html
if not exist "%DANEW_INDEX%" set DANEW_INDEX=%DANEW_REPORTS%\sav-diagnostic-report.html
if not exist "%DANEW_INDEX%" set DANEW_INDEX=%DANEW_REPORTS%\one-click-diagnostic-report.html
if not exist "%DANEW_INDEX%" set DANEW_INDEX=%DANEW_REPORTS%\timeline-raw.html
if not exist "%DANEW_INDEX%" set DANEW_INDEX=%DANEW_REPORTS%\offline-windows-failure-report.html
if not exist "%DANEW_INDEX%" set DANEW_INDEX=%DANEW_REPORTS%\export-summary.html
if not exist "%DANEW_INDEX%" (
    echo [DANEW] Report index not found under %DANEW_REPORTS%.
    exit /b 2
)

call "%~dp0SetHtmlAssociation.cmd" /quiet >nul 2>nul

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
    echo [DANEW] Opening %DANEW_INDEX% with %DANEW_BROWSER%
    "%DANEW_BROWSER%" "%DANEW_INDEX%"
    exit /b 0
)

echo [DANEW] Navigateur HTML non disponible. Consultez les rapports TXT/CSV dans le dossier reports.
echo [DANEW] Reports folder: %DANEW_REPORTS%
exit /b 0

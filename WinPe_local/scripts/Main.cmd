@echo off
setlocal enabledelayedexpansion
set DANEW_PS=
if exist X:\Program Files\PowerShell\7\pwsh.exe set DANEW_PS=X:\Program Files\PowerShell\7\pwsh.exe
if not defined DANEW_PS if exist X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe set DANEW_PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
if not defined DANEW_PS (
  where pwsh.exe >nul 2>nul
  if not errorlevel 1 set DANEW_PS=pwsh.exe
)
if not defined DANEW_PS (
  where powershell.exe >nul 2>nul
  if not errorlevel 1 set DANEW_PS=powershell.exe
)
if not defined DANEW_PS (
  echo [DANEW] PowerShell is not available in this WinPE image.
  echo [DANEW] Add WinPE-PowerShell optional component before booting this media.
  exit /b 127
)
set DANEW_ROOT=
for %%L in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist %%L:\scripts\launcher.ps1 set DANEW_ROOT=%%L:\
)
if not defined DANEW_ROOT (
  echo [DANEW] launcher.ps1 not found on USB partitions.
  exit /b 1
)
"%DANEW_PS%" -NoLogo -ExecutionPolicy Bypass -File %DANEW_ROOT%scripts\launcher.ps1 -RootPath %DANEW_ROOT% -FallbackToCli
if errorlevel 1 "%DANEW_PS%" -NoLogo -ExecutionPolicy Bypass -File %DANEW_ROOT%scripts\DanewCheckTool.CLI.ps1 -RootPath %DANEW_ROOT% -Command Interactive
exit /b %errorlevel%

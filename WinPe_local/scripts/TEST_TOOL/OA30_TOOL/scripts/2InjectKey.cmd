@echo.
@echo **********************************
@echo Start to inject key
@echo **********************************
@echo.
cd /d C:\TEST_TOOL\OA30_TOOL\inject_key
afuwin /aoa3.bin
if %errorlevel% NEQ 0 goto :ERROR
@echo.
goto :RESTART

:ERROR
@echo.
@echo An error has been detected.
@echo. 
pause
goto :END

:RESTART
@echo.
xcopy c:\TEST_TOOL\OA30_TOOL\scripts\3ReportOA3.cmd c:\Users\Administrator\Desktop\OA3 /y
del /f /q c:\Users\Administrator\Desktop\OA3\2InjectKey.cmd
goto :EDN
@echo.


:END

cd /d C:\TEST_TOOL\OA30_TOOL\oa3_tool
oa3tool /report /configfile=oa3tool.cfg
if %errorlevel% NEQ 0 goto :ERROR
@echo.
xcopy c:\TEST_TOOL\OA30_TOOL\scripts\4Barcode.cmd c:\Users\Administrator\Desktop\OA3 /y
del /f /q c:\Users\Administrator\Desktop\OA3\3ReportOA3.cmd
@echo.
goto :END

:ERROR
@echo.
@echo An error has been detected.
@echo. 
pause
goto :END

:END

@echo **********************************
@echo Start OA3.0 Tool
@echo **********************************
@echo.
cd /d C:\TEST_TOOL\OA30_TOOL\oa3_tool
oa3tool /assemble /configfile=oa3tool.cfg
if %errorlevel% NEQ 0 goto :ERROR
xcopy c:\TEST_TOOL\OA30_TOOL\scripts\2InjectKey.cmd c:\Users\Administrator\Desktop\OA3 /y
del /f /q c:\Users\Administrator\Desktop\OA3\1StartOA3Tool.cmd
@echo.
goto :END

:ERROR
@echo.
@echo An error has been detected.
@echo.
pause
goto :END

:END

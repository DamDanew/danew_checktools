cd /d c:\TEST_TOOL\OA30_TOOL\inject_key
set NODE=ProductKeyID
set XML=OA3.xml
for /f "tokens=3 delims=>" %%i in ('findstr "<%NODE%>" %XML%') do (
    for /f "delims=<" %%i in ("%%i")do (
	set PRID=%%i
    )
)
@echo ***********************************
@echo.
@echo.
@echo.
@echo.
@echo.
@echo.
@echo.
@echo.
@echo ProductKeyID£º   %PRID%
@echo.
@echo.
@echo.
@echo.
@echo.
@echo.
@echo.
@echo ***********************************
pause


net user administrator /active:no
rmdir /s /q c:\TEST_TOOL
rmdir /s /q c:\OA3TOOL
rmdir /s /q c:\MDATOOL
del /f /q %userprofile%\Desktop\START_TEST.cmd
del /f /q %userprofile%\Desktop\StartOA3Tool.cmd
del /f /q %userprofile%\Desktop\Desktop\temp
del /f /q %userprofile%\Desktop\SMT_shutdown.cmd
del /f /q %userprofile%\Desktop\1StartOA3Tool.cmd
del /f /q %userprofile%\Desktop\*.MP4
del /f /q %userprofile%\Desktop\SN.lnk
del /f /q %userprofile%\Desktop\rebooter.exe

@REM CleanupTestTool.cmd  must be last to be deleted
taskkill /f /im sysprep.exe
call c:\Windows\System32\Sysprep\Sysprep.exe  -OOBE -shutdown
if %errorlevel% NEQ 0 echo Sysprep failed. && goto :error
del /f /q %userprofile%\Desktop\CleanupTestTool.cmd
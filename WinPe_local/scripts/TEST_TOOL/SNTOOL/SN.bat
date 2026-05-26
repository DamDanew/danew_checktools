@echo off
cd /d %~dp0

:WSSN
cls
color F
REM ################### SS ####################
set /p SS=Scan SN:
EMDoorRecover.exe /SS %SS%
if errorlevel 1 goto FAIL_SS
AMIDEWIN.exe /SS > SN.TXT
FIND "%SS%" SN.TXT
copy sn.txt C:\Users\%username%\Desktop
if errorlevel==1 goto FAIL_SS
if errorlevel==0 goto PASS
:PASS
CLS
COLOR F2
ECHO ******************************
ECHO SN writed sucessfully!
ECHO ******************************
timeout 1
GOTO END

:FAIL_SS
color fc
echo #########################################
echo        Write SN FAIL
echo #########################################
timeout 2
goto WSSN


:END



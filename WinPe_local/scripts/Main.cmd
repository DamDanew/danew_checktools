echo.
echo Running command to active high-performance power scheme
echo powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

echo. 
echo Check %WinPESource%images
if exist %WinPESource%images\install.wim echo Find %WinPESource%images\install.wim && set IMAGETYPE=WIM
if exist %WinPESource%images\install.swm echo Find %WinPESource%images\install.swm && set IMAGETYPE=SWM
if not defined IMAGETYPE echo Image not find in %WinPESource%images && goto :ERROR

REM eMMC disk is the first choice to install Windows
echo.
echo Try to find a fixed internal disk
echo.
for /l %%i in (3,-1,0) do (
    echo select disk %%i > x:\detdisk.txt
	echo detail disk >> x:\detdisk.txt
	diskpart /s x:\detdisk.txt > x:\det.txt
	find /i "Type   : UFS" x:\det.txt
	if not errorlevel 1 set Disk=%%i
)
if defined Disk goto :FORMAT

for /l %%i in (3,-1,0) do (
    echo select disk %%i > x:\detdisk.txt
	echo detail disk >> x:\detdisk.txt
	diskpart /s x:\detdisk.txt > x:\det.txt
	find /i "Type   : SD" x:\det.txt
	if not errorlevel 1 set Disk=%%i
)
if defined Disk goto :FORMAT

for /l %%i in (3,-1,0) do (
    echo select disk %%i > x:\detdisk.txt
	echo detail disk >> x:\detdisk.txt
	diskpart /s x:\detdisk.txt > x:\det.txt
	find /i "Type   : NVMe" x:\det.txt
	if not errorlevel 1 set Disk=%%i
)
if defined Disk goto :FORMAT


REM If no eMMC disk exists,then use SSD/HDD(SATA interface only)
for /l %%i in (3,-1,0) do (
    echo select disk %%i > x:\detdisk.txt
	echo detail disk >> x:\detdisk.txt
	diskpart /s x:\detdisk.txt > x:\det.txt
	find /i "Type   : SATA" x:\det.txt
	if not errorlevel 1 set Disk=%%i
)
if not defined Disk echo Cannot find a fixed internal disk. && goto :ERROR

:FORMAT
echo.
echo Using disk %Disk%

echo.
echo select disk "%Disk%" > x:\winpart.txt
echo clean >> x:\winpart.txt
echo convert gpt >> x:\winpart.txt
echo create partition efi size=300 >> x:\winpart.txt
echo format quick fs=fat32 label="System" >> x:\winpart.txt
echo assign letter="S" >> x:\winpart.txt
echo create partition msr size=16 >> x:\winpart.txt
echo create partition primary >> x:\winpart.txt
echo format quick fs=ntfs label="Windows" >> x:\winpart.txt
echo assign letter="W" >> x:\winpart.txt
echo shrink desired=1200 >> x:\winpart.txt
echo create partition primary >> x:\winpart.txt
echo format quick fs=ntfs label="Recovery" >> x:\winpart.txt
echo assign letter="R" >> x:\winpart.txt
echo set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac" >> x:\winpart.txt
echo gpt attributes=0x8000000000000001 >> x:\winpart.txt
echo exit >> x:\WinPart.txt
echo Winpart.txt now contains.....
echo.
type x:\winpart.txt
echo.
echo diskpart /s x:\winpart.txt
diskpart /s x:\winpart.txt
ping 127.0.0.1 -n 5 > x:\delay.txt
if not exist W:\ echo Diskpart failed to format disk. && goto :ERROR

echo.
echo Making directories...
echo w:\recycler\scratch
echo r:\recovery\windowsre
md w:\recycler\scratch
if errorlevel 1 echo Failed to make w:\recycler\scratch directory && goto :ERROR
md r:\recovery\windowsre
if errorlevel 1 echo Failed to make r:\recovery\windowsre directory && goto :ERROR

echo.
echo Applying image to Windows partition
if /i "%IMAGETYPE%"=="WIM" (
    DISM /Apply-Image /ImageFile:%WinPESource%images\install.wim /Index:1 /ApplyDir:w: /Compact /EA /ScratchDir:w:\recycler\SCRATCH
    if errorlevel 1 echo Failed to apply image. && goto :ERROR
) else (
	DISM /Apply-Image /ImageFile:%WinPESource%images\install.swm /SwmFile:%WinPESource%images\install*.swm /Index:1 /ApplyDir:w: /Compact /EA /ScratchDir:w:\recycler\SCRATCH
	if errorlevel 1 echo Failed to apply image. && goto :ERROR
)

echo.
echo Moving WinRE to Recovery Partition
attrib  w:\Windows\System32\recovery\winre.wim -s -h -a -r
@echo move w:\Windows\System32\recovery\winre.wim r:\recovery\windowsre
move  w:\Windows\System32\recovery\winre.wim r:\recovery\windowsre 
::copy %WinPESource%images\winre.wim r:\recovery\windowsre 
if errorlevel 1 echo Failed to move winre.wim to R:\recovery\windowsre && goto :ERROR
attrib r:\Recovery\Windowsre\winre.wim +s +h +a +r

echo.
echo Setting BCD on EFI partition
echo W:\WINDOWS\SYSTEM32\BCDBOOT w:\WINDOWS /s s: /f all
W:\WINDOWS\SYSTEM32\BCDBOOT w:\WINDOWS /s s: /f all
if errorlevel 1 echo Failed to set BCD on EFI partition. && goto :ERROR

echo.
echo Setting hardware recovery button for BIOS trigger
echo.
md S:\EFI\Recovery
xcopy /e /h S:\EFI\Microsoft\* S:\EFI\Recovery\
del /a S:\EFI\Recovery\Boot\BCD
del /a S:\EFI\Recovery\Boot\BCD.LOG
bcdedit /createstore S:\BCD
if %errorlevel% NEQ 0 echo Failed to set recovery information in efi && goto :ERROR
bcdedit /store S:\BCD /create {bootmgr} /d "Windows Boot Manager"
bcdedit /store S:\BCD /set {bootmgr} device partition=S:
bcdedit /store S:\BCD /set {bootmgr} locale en-US
bcdedit /store S:\BCD /set {bootmgr} integrityservices Enable
if %errorlevel% NEQ 0 echo Failed to set recovery information in efi && goto :ERROR
bcdedit /store S:\BCD /create {11111111-1111-1111-1111-111111111111} /d "Windows Recovery" /device
bcdedit /store S:\BCD /set {11111111-1111-1111-1111-111111111111} ramdisksdidevice partition=R:
bcdedit /store S:\BCD /set {11111111-1111-1111-1111-111111111111} ramdisksdipath  \Recovery\WindowsRE\boot.sdi
if %errorlevel% NEQ 0 echo Failed to set recovery information in efi && goto :ERROR
bcdedit /store S:\BCD /create {22222222-2222-2222-2222-222222222222} /d "Windows Recovery Environment" /application osloader
bcdedit /store S:\BCD /set {bootmgr} default {22222222-2222-2222-2222-222222222222}
bcdedit /store S:\BCD /set {bootmgr} displayorder {22222222-2222-2222-2222-222222222222}
if %errorlevel% NEQ 0 echo Failed to set recovery information in efi && goto :ERROR
bcdedit /store S:\BCD /set {default} device ramdisk=[R:]\Recovery\WindowsRE\winre.wim,{11111111-1111-1111-1111-111111111111}
bcdedit /store S:\BCD /set {default} path \Windows\System32\winload.efi
bcdedit /store S:\BCD /set {default} locale en-US
bcdedit /store S:\BCD /set {default} displaymessage "Recovery"
bcdedit /store S:\BCD /set {default} osdevice ramdisk=[R:]\Recovery\WindowsRE\winre.wim,{11111111-1111-1111-1111-111111111111}
bcdedit /store S:\BCD /set {default} systemroot \Windows
bcdedit /store S:\BCD /set {default} nx OptIn
bcdedit /store S:\BCD /set {default} bootmenupolicy Standard
bcdedit /store S:\BCD /set {default} winpe Yes
if %errorlevel% NEQ 0 echo Failed to set recovery information in efi && goto :ERROR
xcopy /h S:\BCD* S:\EFI\Recovery\Boot\
if %errorlevel% NEQ 0 echo Failed to set recovery information in efi && goto :ERROR
del /a S:\BCD*
if %errorlevel% NEQ 0 echo Failed to set recovery information in efi && goto :ERROR

echo.
echo Updating WinRE association
echo w:\windows\system32\reagentc /SetREImage /Path r:\RECOVERY\WINDOWSRE /target w:\windows
w:\windows\system32\reagentc /SetREImage /Path r:\RECOVERY\WINDOWSRE /target w:\windows
if errorlevel 1 echo Failed to set recovery enviroment. && goto :ERROR

echo.
echo Copying test tool and customization files

echo.
echo xcopy %WinPESource%Scripts\TEST_TOOL W:\TEST_TOOL /e /i /y
xcopy %WinPESource%Scripts\TEST_TOOL W:\TEST_TOOL /e /i /y

::echo.
::echo xcopy %WinPESource%Scripts\GW_TEST W:\users\administrator\desktop\GW_TEST /e /i /y
::xcopy %WinPESource%Scripts\GW_TEST W:\users\administrator\desktop\GW_TEST /e /i /y

::echo.
::echo copy %WinPESource%Scripts\GW_TEST.lnk W:\users\administrator\desktop\GW_TEST.lnk /y
::copy %WinPESource%Scripts\GW_TEST.lnk W:\users\administrator\desktop\GW_TEST.lnk /y

::echo.
::echo xcopy %WinPESource%oem\Scripts\oobe\Info w:\Windows\System32\oobe\Info /e /y /i
xcopy w:\RECOVERY\OEM\Scripts\oobe\Info w:\Windows\System32\oobe\Info /e /y /i

echo.
echo xcopy %WinPESource%OEM w:\RECOVERY\OEM /y /e /i
xcopy %WinPESource%OEM w:\RECOVERY\OEM /y /e /i
xcopy w:\RECOVERY\OEM\Scripts\OEM w:\Windows\OEM /y /e /i

echo.
echo copy %WinPESource%Scripts\Unattend.xml w:\Windows\Panther\ /y
copy %WinPESource%Scripts\Unattend.xml w:\Windows\Panther\ /y

echo. 

echo. 
echo copy %WinPESource%oem\Scripts\csup.txt w:\Windows\ /y
copy w:\RECOVERY\OEM\Scripts\csup.txt w:\Windows\ /y

::echo. 
::echo copy %WinPESource%oem\Scripts\win.txt w:\Windows\System32\ /y
::copy %WinPESource%oem\Scripts\win.txt w:\Windows\System32\ /y
dism /image:w:\ /add-driver /driver:w:\TEST_TOOL\driver  /recurse

echo. 
echo copy %WinPESource%oem\Scripts\oemlogo.bmp w:\Windows\Panther\ /y
copy %WinPESource%oem\Scripts\oemlogo.bmp w:\Windows\Panther\ /y

::echo. 
::echo copy %WinPESource%oem\Scripts\oembackground.jpg w:\Windows\web\wallpaper\ /y
::copy %WinPESource%oem\Scripts\oembackground.jpg w:\Windows\web\wallpaper\ /y

echo.
echo copy %WinPESource%oem\Scripts\LayoutModification.xml W:\Users\Default\AppData\Local\Microsoft\Windows\Shell\ /y
copy %WinPESource%oem\Scripts\LayoutModification.xml W:\Users\Default\AppData\Local\Microsoft\Windows\Shell\ /y

::echo.
::echo Writing image SN to C:\RECOVERY\OEM\ImageSN.txt
::echo WH-10.1-JX-S133GR210-227-A>w:\RECOVERY\OEM\ImageSN.txt
rd /s /q w:\recycler

echo.
echo ****************************************************
echo   Image deployment COMPLETED. Type EXIT to reboot.
echo   Type WPEUTIL SHUTDOWN to shutdown the system.
echo ****************************************************
goto END

:ERROR
echo.
echo *************************************************************
echo   An error has been detected,the procedure cannot continue.
echo *************************************************************

:END
Wpeutil Reboot
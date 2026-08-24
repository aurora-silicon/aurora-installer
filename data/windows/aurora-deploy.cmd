@echo off
rem SPDX-License-Identifier: MIT
rem Apply a pinned Windows ARM64 image only to the installer-marked target.
setlocal EnableExtensions EnableDelayedExpansion

set "MEDIA=%~d0\"
set "OUT=X:\AuroraDeploy"
set "CFG=%MEDIA%Aurora\deploy.cfg"
set "WINVOL="
set "ESPVOL="
set "WINCOUNT=0"
set "ESPCOUNT=0"
set "BCDERR=0"
if not exist "%OUT%" mkdir "%OUT%" >nul 2>&1

if not exist "%CFG%" goto abort_config
for /f "usebackq tokens=1,* delims==" %%A in ("%CFG%") do set "%%A=%%B"
if not "!schema!"=="1" goto abort_config
if "!token!"=="" goto abort_config
if "!disk_number!"=="" goto abort_config
if "!disk_guid!"=="" goto abort_config
if "!esp_partition_number!"=="" goto abort_config
if "!image_name!"=="" goto abort_config
if "!iso_sha256!"=="" goto abort_config
if "!driver_pack_sha256!"=="" goto abort_config

set "MEDIA_TOKEN="
set /p MEDIA_TOKEN=<"%MEDIA%AURORA-WINDOWS-MEDIA.TAG"
if /I not "!MEDIA_TOKEN!"=="!token!" goto abort_config
if not exist "%MEDIA%sources\install.wim" if not exist "%MEDIA%sources\install.esd" goto abort_config
if not exist "%MEDIA%Aurora\Drivers\boot-drivers.txt" goto abort_config

call :emit "AURORA_DEPLOY_BEGIN build=!windows_build! disk=!disk_guid!"

rem Load boot-critical drivers before asking Windows to enumerate the SSD.
for /f "usebackq eol=# delims=" %%I in ("%MEDIA%Aurora\Drivers\boot-drivers.txt") do (
    call :emit "AURORA_DRVLOAD %%I"
    drvload.exe "%MEDIA%Aurora\Drivers\%%I" >"%OUT%\drvload.txt" 2>&1
    if errorlevel 1 goto abort_driver
)
pnputil.exe /scan-devices >"%OUT%\scan-devices.txt" 2>&1

rem Bind every later write to the exact GPT disk selected by the macOS phase.
(
    echo rescan
    echo select disk !disk_number!
    echo detail disk
    echo uniqueid disk
    echo list partition
) >"%OUT%\identity.diskpart"
diskpart.exe /s "%OUT%\identity.diskpart" >"%OUT%\identity.txt" 2>&1
set "DISKID="
for /f "tokens=3" %%G in ('find.exe /i "Disk ID" ^< "%OUT%\identity.txt"') do set "DISKID=%%G"
call :emit "AURORA_DISK_ID=!DISKID! expected={!disk_guid!}"
if /I not "!DISKID!"=="{!disk_guid!}" goto abort_identity

rem The target was temporarily formatted exFAT by macOS solely so this unique
rem marker could survive into WinPE. Refuse zero or multiple matches.
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\AURORA-WINDOWS-TARGET.TAG" (
        set "TARGET_TOKEN="
        set /p TARGET_TOKEN=<"%%D:\AURORA-WINDOWS-TARGET.TAG"
        if /I "!TARGET_TOKEN!"=="!token!" (
            set /a WINCOUNT+=1
            set "WINVOL=%%D:"
        )
    )
    if exist "%%D:\AURORA-ESP.TAG" (
        set "ESP_TOKEN="
        set /p ESP_TOKEN=<"%%D:\AURORA-ESP.TAG"
        if /I "!ESP_TOKEN!"=="!token!" (
            set /a ESPCOUNT+=1
            set "ESPVOL=%%D:"
        )
    )
)
if not "!WINCOUNT!"=="1" goto abort_target

rem ESPs are commonly hidden. It is safe to assign S: only after the disk GUID
rem is proven and only to the partition number recorded by the installer.
if "!ESPCOUNT!"=="0" (
    (
        echo select disk !disk_number!
        echo select partition !esp_partition_number!
        echo assign letter=S
    ) >"%OUT%\mount-esp.diskpart"
    diskpart.exe /s "%OUT%\mount-esp.diskpart" >"%OUT%\mount-esp.txt" 2>&1
    if exist "S:\AURORA-ESP.TAG" (
        set "ESP_TOKEN="
        set /p ESP_TOKEN=<"S:\AURORA-ESP.TAG"
        if /I "!ESP_TOKEN!"=="!token!" (
            set "ESPVOL=S:"
            set "ESPCOUNT=1"
        )
    )
)
if not "!ESPCOUNT!"=="1" goto abort_target
if /I "!WINVOL!"=="!ESPVOL!" goto abort_target
if /I "!WINVOL!"=="%MEDIA:~0,2%" goto abort_target

call :emit "AURORA_TARGET windows=!WINVOL! esp=!ESPVOL! media=%MEDIA%"
call :emit "AURORA_WRITE_BOUNDARY_VERIFIED"

rem This is the first destructive target operation. Nothing above changed the
rem target disk. The marker-selected exFAT target is now converted to NTFS.
(
    echo select volume !WINVOL:~0,1!
    echo format fs=ntfs quick label=Windows
) >"%OUT%\format-target.diskpart"
diskpart.exe /s "%OUT%\format-target.diskpart" >"%OUT%\format-target.txt" 2>&1
if errorlevel 1 goto abort_format
find.exe /i "DiskPart successfully formatted the volume" <"%OUT%\format-target.txt" >nul
if errorlevel 1 goto abort_format
if not exist "!WINVOL!\" goto abort_format
fsutil.exe fsinfo volumeinfo !WINVOL! >"%OUT%\target-fs.txt" 2>&1
find.exe /i "NTFS" <"%OUT%\target-fs.txt" >nul
if errorlevel 1 goto abort_format

if exist "%MEDIA%sources\install.wim" (
    set "IMAGE_FILE=%MEDIA%sources\install.wim"
) else (
    set "IMAGE_FILE=%MEDIA%sources\install.esd"
)
call :emit "AURORA_APPLY_IMAGE name=!image_name! source=!IMAGE_FILE!"
Dism.exe /Apply-Image /ImageFile:"!IMAGE_FILE!" /Name:"!image_name!" /ApplyDir:!WINVOL!\ >"%OUT%\apply-image.txt" 2>&1
if errorlevel 1 goto abort_apply

call :emit "AURORA_INJECT_DRIVERS"
Dism.exe /Image:!WINVOL!\ /Add-Driver /Driver:"%MEDIA%Aurora\Drivers" /Recurse /ForceUnsigned >"%OUT%\add-drivers.txt" 2>&1
if errorlevel 1 goto abort_dism

if not exist "!WINVOL!\Windows\System32\winload.efi" goto abort_apply
if not exist "!WINVOL!\Windows\Setup\Scripts" mkdir "!WINVOL!\Windows\Setup\Scripts"
copy /y "%MEDIA%Aurora\SetupComplete.cmd" "!WINVOL!\Windows\Setup\Scripts\SetupComplete.cmd" >nul

call :emit "AURORA_INSTALL_BOOT_FILES"
"!WINVOL!\Windows\System32\bcdboot.exe" "!WINVOL!\Windows" /s !ESPVOL! /f UEFI >"%OUT%\bcdboot.txt" 2>&1
if errorlevel 1 goto abort_bcd
set "BCD=!ESPVOL!\EFI\Microsoft\Boot\BCD"
if not exist "!BCD!" goto abort_bcd

call :bcd /store "!BCD!" /set {default} testsigning on
call :bcd /store "!BCD!" /set {bootmgr} default {default}
bcdedit.exe /store "!BCD!" /enum {default} >"%OUT%\bcd-after.txt" 2>&1
if not "!BCDERR!"=="0" goto abort_bcd
find.exe /i "testsigning" <"%OUT%\bcd-after.txt" >nul
if errorlevel 1 goto abort_bcd

rem Mu enters the removable-media fallback path rather than a firmware NVRAM
rem boot option. Preserve the one-shot setup loader, then make that stable path
rem enter the Windows installation BCDBoot just created.
if not exist "!ESPVOL!\EFI\Microsoft\Boot\bootmgfw.efi" goto abort_bcd
if not exist "!ESPVOL!\EFI\Boot" mkdir "!ESPVOL!\EFI\Boot"
if exist "!ESPVOL!\EFI\Boot\bootaa64.efi" (
    copy /y "!ESPVOL!\EFI\Boot\bootaa64.efi" "!ESPVOL!\EFI\Boot\aurora-setup.efi" >nul
)
copy /y "!ESPVOL!\EFI\Microsoft\Boot\bootmgfw.efi" "!ESPVOL!\EFI\Boot\bootaa64.efi" >nul
if errorlevel 1 goto abort_bcd

echo build=!windows_build!>"!WINVOL!\AuroraWindowsInstalled.txt"
echo iso_sha256=!iso_sha256!>>"!WINVOL!\AuroraWindowsInstalled.txt"
echo driver_pack_sha256=!driver_pack_sha256!>>"!WINVOL!\AuroraWindowsInstalled.txt"
echo test_signing=on>>"!WINVOL!\AuroraWindowsInstalled.txt"
call :emit "AURORA_DEPLOY_COMPLETE"
wpeutil.exe reboot
exit /b 0

:bcd
bcdedit.exe %* >"%OUT%\bcd-step.txt" 2>&1
set "RC=!ERRORLEVEL!"
if not "!RC!"=="0" set /a BCDERR+=1
call :emit "bcdedit rc=!RC! %*"
exit /b 0

:emit
echo %~1
exit /b 0

:abort_config
echo AURORA_DEPLOY_ABORT invalid or incomplete deployment configuration
goto shell
:abort_driver
call :emit "AURORA_DEPLOY_ABORT boot-critical driver failed before target writes"
goto shell
:abort_identity
call :emit "AURORA_DEPLOY_ABORT GPT disk identity mismatch -- target untouched"
goto shell
:abort_target
call :emit "AURORA_DEPLOY_ABORT target or ESP marker is missing/ambiguous -- target untouched"
goto shell
:abort_format
call :emit "AURORA_DEPLOY_ABORT target NTFS format failed"
goto shell
:abort_apply
call :emit "AURORA_DEPLOY_ABORT Windows image apply failed"
goto shell
:abort_dism
call :emit "AURORA_DEPLOY_ABORT offline driver injection failed"
goto shell
:abort_bcd
call :emit "AURORA_DEPLOY_ABORT UEFI BCD/test-signing configuration failed"
goto shell

:shell
echo.
echo Deployment stopped. The system will not reboot automatically.
cmd.exe
exit /b 1

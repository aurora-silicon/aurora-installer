@echo off
setlocal EnableExtensions EnableDelayedExpansion
wpeinit

set "AURORA_DEPLOY="
set "AURORA_COUNT=0"
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\Aurora\aurora-deploy.cmd" if exist "%%D:\Aurora\deploy.cfg" (
        set /a AURORA_COUNT+=1
        set "AURORA_DEPLOY=%%D:\Aurora\aurora-deploy.cmd"
    )
)

if not "!AURORA_COUNT!"=="1" goto shell
call "!AURORA_DEPLOY!"

:shell
echo.
echo Aurora deployment did not reboot. Review the messages above before doing anything.
cmd.exe

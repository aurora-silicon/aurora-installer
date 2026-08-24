@echo off
rem Keep the installed loader in test-signing mode after Setup and servicing.
bcdedit.exe /set {current} testsigning on >"%SystemRoot%\Temp\aurora-testsigning.log" 2>&1
exit /b %ERRORLEVEL%

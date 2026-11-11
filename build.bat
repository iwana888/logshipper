@echo off
REM Build logshipper with FPC (Windows).
fpc -Mobjfpc -Sh -O2 -Fu. logshipper.lpr
if errorlevel 1 exit /b 1
echo built: logshipper.exe

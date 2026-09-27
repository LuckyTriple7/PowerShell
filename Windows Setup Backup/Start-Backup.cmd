@echo off
rem Keep the result visible while preserving the PowerShell exit code.
powershell.exe -NoProfile -File "%~dp0Backup-WindowsSetup.ps1" %*
set "code=%errorlevel%"
pause
exit /b %code%

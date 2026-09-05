@echo off
rem Keep the console open so that the result or errors remain visible.
powershell.exe -NoProfile -NoExit -File "%~dp0Backup-WindowsSetup.ps1" %*

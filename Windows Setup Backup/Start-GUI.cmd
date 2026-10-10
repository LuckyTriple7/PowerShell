@echo off
rem A separate console remains available for startup errors; the GUI shows job output.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0WindowsSetup-GUI.ps1"
if errorlevel 1 pause

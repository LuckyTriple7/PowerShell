@echo off
REM Startet den MP3 Tag Editor mit STA (noetig fuer WinForms) und ohne ExecutionPolicy-Stolpern.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Mp3TagEditor.ps1"
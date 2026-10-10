@echo off
rem Installs or updates a local copy. GuiState (settings, schedules, logs) then stays on this machine instead of syncing through OneDrive.
setlocal
set "SOURCE=%~dp0"
set "TARGET=C:\Windows Setup Backup"
if /i "%SOURCE%"=="%TARGET%\" (
    echo Setup.cmd bitte aus dem OneDrive-Ordner starten, nicht aus "%TARGET%".
    pause
    exit /b 1
)
robocopy "%SOURCE%." "%TARGET%" *.ps1 *.cmd *.md VERSION /R:2 /W:2 /NJH /NJS /NDL /NP
if errorlevel 8 (
    echo.
    echo FEHLER: Nicht alle Dateien konnten kopiert werden.
    pause
    exit /b 1
)
powershell.exe -NoProfile -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Windows Setup Backup.lnk')); $s.TargetPath = Join-Path $env:TARGET 'Start-GUI.cmd'; $s.WorkingDirectory = $env:TARGET; $s.IconLocation = 'imageres.dll,-1004'; $s.Save()"
if errorlevel 1 echo WARNUNG: Die Startmenue-Verknuepfung konnte nicht angelegt werden.
set /p VERSION=<"%TARGET%\VERSION"
echo.
echo Version %VERSION% liegt in "%TARGET%". Einstellungen und Zeitplan dort bleiben unveraendert.
echo Start: Startmenue "Windows Setup Backup" oder "%TARGET%\Start-GUI.cmd".
pause

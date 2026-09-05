#requires -Version 5.1
<#
.SYNOPSIS
Sichert Programmlisten, Startmenue und ausgewaehlte Benutzereinstellungen.
.EXAMPLE
.\Backup-WindowsSetup.ps1 -IncludeDeveloperSettings
#>
[CmdletBinding()]
param(
    [string]$Destination = 'C:\Users\andre\OneDrive\Backup\Windows\GigabyteA16',
    [switch]$IncludeDeveloperSettings,
    [switch]$SkipWinget,
    [switch]$AcceptSourceAgreements,
    [switch]$SkipPython,
    [string[]]$PythonExecutables = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
$timer = [Diagnostics.Stopwatch]::StartNew()
$logPath = $null
function Write-BackupStatus {
    param([string]$Message, [ConsoleColor]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    if ($logPath) { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 }
}
function Write-BackupStep {
    param([int]$Number, [string]$Message)
    Write-BackupStatus "[$Number/8] $Message" -Color Cyan
    Write-Progress -Id 1 -Activity 'Windows-Setup sichern' -Status $Message -PercentComplete ([int](($Number - 1) / 8 * 100))
}
function Add-BackupWarning {
    param([string]$Message)
    $warnings.Add($Message)
    Write-BackupStatus "WARNUNG: $Message" -Color Yellow
}

try {
Write-BackupStatus 'Windows-Setup-Backup wird gestartet.' -Color Cyan
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backup = Join-Path ([IO.Path]::GetFullPath($Destination)) "$env:COMPUTERNAME-$stamp"
New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
$logPath = Join-Path $backup 'backup.log'
Write-BackupStatus "Sicherungsordner: $backup"
Write-BackupStatus ('Entwicklereinstellungen: ' + $(if ($IncludeDeveloperSettings) { 'eingeschlossen' } else { 'nicht ausgewaehlt (optional: -IncludeDeveloperSettings)' }))
$warnings = [Collections.Generic.List[string]]::new()
$files = [Collections.Generic.List[object]]::new()
$wingetReady = $false
$startLayoutReady = $false
$packageCount = 0
$storeCount = $null
$pythonResult = $null
$pythonStatus = 'nicht gesichert'

# Read uninstall keys directly: Win32_Product can trigger MSI repair operations.
Write-BackupStep 1 'Installierte Programme erfassen ...'
$programs = @(
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root | ForEach-Object {
                $p = Get-ItemProperty -LiteralPath $_.PSPath
                if ($p.DisplayName) {
                    [pscustomobject]@{ Name = $p.DisplayName; Version = $p.DisplayVersion; Publisher = $p.Publisher
                        InstallLocation = $p.InstallLocation; RegistryPath = $_.Name }
                }
            }
        }
    }
) | Sort-Object Name, Version
Write-SetupJson -Value @($programs) -Path (Join-Path $backup 'installed-programs.json')
$programs | Export-Csv -LiteralPath (Join-Path $backup 'installed-programs.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
Write-BackupStatus ("{0} Programmeintraege erfasst." -f @($programs).Count)
Write-BackupStep 2 'Microsoft-Store-Apps erfassen ...'
try {
    $apps = @(Get-AppxPackage | Select-Object Name, Version, PackageFamilyName)
    Write-SetupJson -Value $apps -Path (Join-Path $backup 'store-apps.json')
    $storeCount = $apps.Count
    Write-BackupStatus "$storeCount Store-App-Eintraege erfasst."
} catch { Add-BackupWarning "Store-Inventar fehlgeschlagen: $_" }

Write-BackupStep 3 'WinGet-Programmliste exportieren (kann mehrere Minuten dauern) ...'
if (-not $SkipWinget) {
    try {
        $winget = (Get-Command winget.exe -ErrorAction Stop).Source
        $arguments = @('export','--output',(Join-Path $backup 'winget-packages.json'),'--include-versions','--disable-interactivity')
        if ($AcceptSourceAgreements) { $arguments += '--accept-source-agreements' }
        # Native stderr must be captured without PowerShell 5.1 terminating early.
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $winget @arguments > (Join-Path $backup 'winget-export.log') 2>&1
            $wingetExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $oldPreference }
        if ($wingetExit -ne 0) { throw "WinGet Exitcode $wingetExit; siehe winget-export.log." }
        $export = Get-Content -LiteralPath (Join-Path $backup 'winget-packages.json') -Raw | ConvertFrom-Json
        if (-not $export.Sources) { throw 'WinGet hat keine Paketquellen exportiert.' }
        $wingetReady = $true
        $packageCount = @($export.Sources | ForEach-Object { $_.Packages }).Count
        Write-BackupStatus "$packageCount WinGet-Pakete exportiert. Zuordnungswarnungen stehen in winget-export.log."
    } catch { Add-BackupWarning "Programminstallationsliste unvollstaendig: $_" }
} else { Add-BackupWarning 'WinGet wurde uebersprungen. Programme sind nur inventarisiert.' }

Write-BackupStep 4 'Python-/pip-Pakete je Umgebung erfassen ...'
if ($SkipPython) {
    $pythonStatus = 'uebersprungen (-SkipPython)'
    Write-BackupStatus $pythonStatus
} else {
    try {
        $pythonResult = & (Join-Path $PSScriptRoot 'Backup-PythonPackages.ps1') -Destination (Join-Path $backup 'Python') -PythonExecutables $PythonExecutables
        foreach ($warning in $pythonResult.Warnings) { Add-BackupWarning $warning }
        $pythonStatus = "$($pythonResult.ExportedCount)/$($pythonResult.FoundCount) Umgebungen exportiert, $($pythonResult.PackageCount) Paketeintraege"
        Write-BackupStatus $pythonStatus
    } catch { Add-BackupWarning "Python-Paketsicherung fehlgeschlagen: $_" }
}

Write-BackupStep 5 'Startmenue-Verknuepfungen und ausgewaehlte Konfigurationen kopieren ...'
$locations = Get-SetupLocations
foreach ($key in $locations.Keys) {
    $location = $locations[$key]
    if ($location.Developer -and -not $IncludeDeveloperSettings) { continue }
    if (-not (Test-Path -LiteralPath $location.Path)) {
        Write-BackupStatus "${key}: nicht vorhanden, ausgelassen."
        continue
    }
    Write-BackupStatus "${key}: Dateien werden gelesen ..."
    $countBefore = $files.Count
    try {
        $recursive = $key -in @('StartMenuUser','StartMenuCommon','VSCodeSnippets')
        $sourceFiles = @(Get-ChildItem -LiteralPath $location.Path -File -Recurse:$recursive -Force)
        $fileNumber = 0
        foreach ($file in $sourceFiles) {
            $fileNumber++
            $relative = $file.FullName.Substring($location.Path.TrimEnd('\').Length + 1)
            if (-not (Test-SetupFileAllowed $key $relative $location)) { continue }
            Write-Progress -Id 2 -ParentId 1 -Activity "Dateien: $key" -Status "$fileNumber / $($sourceFiles.Count): $relative" -PercentComplete ([int]($fileNumber / $sourceFiles.Count * 100))
            try {
                $stored = "Files\$key\$relative"
                $target = Join-SetupSafePath $backup $stored
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                $files.Add([pscustomobject]@{ Key = $key; Relative = $relative; SHA256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash })
            } catch { Add-BackupWarning "Datei nicht gesichert: $($file.FullName): $_" }
        }
    } catch { Add-BackupWarning "Ordner nicht vollstaendig gelesen: $($location.Path): $_" }
    finally { Write-Progress -Id 2 -Activity "Dateien: $key" -Completed }
    Write-BackupStatus ("${key}: {0} Dateien gesichert." -f ($files.Count - $countBefore))
}
Write-BackupStep 6 'Windows-Einstellungen sichern ...'
$registryValues = @(Get-SetupRegistryValues)
Write-SetupJson -Value $registryValues -Path (Join-Path $backup 'settings-registry.json')
Write-BackupStatus "$($registryValues.Count) Registry-Einstellungen gesichert."

Write-BackupStep 7 'Angeheftetes Startlayout exportieren ...'
try {
    # Export-StartLayout is a Windows PowerShell module. Use 5.1 also when launched from pwsh.
    $windows = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $extension = if ([int]$windows.CurrentBuild -ge 22000) { 'json' } else { 'xml' }
    $layoutPath = Join-Path $backup "start-layout.$extension"
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -NonInteractive -Command "Export-StartLayout -Path '$($layoutPath.Replace("'", "''"))' -ErrorAction Stop" > (Join-Path $backup 'start-layout-export.log') 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $layoutPath)) { throw 'Export-StartLayout fehlgeschlagen; siehe Log.' }
    $startLayoutReady = $true
    Write-BackupStatus 'Startlayout exportiert (spaetere Wiederherstellung der Pins manuell).'
} catch { Add-BackupWarning "Startlayout nicht exportiert: $_" }

Write-BackupStep 8 'Sicherungsverzeichnis und Abschlussbericht schreiben ...'
$windows = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$manifest = [ordered]@{
    SchemaVersion = 1; Created = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME
    User = $env:USERNAME; OriginalProfile = $env:USERPROFILE
    Windows = @{ Edition = $windows.EditionID; Version = $windows.DisplayVersion; Build = $windows.CurrentBuild; UBR = $windows.UBR }
    WingetReady = $wingetReady; StartLayoutReady = $startLayoutReady
    Python = $pythonResult; PythonStatus = $pythonStatus
    DeveloperSettings = [bool]$IncludeDeveloperSettings; Files = @($files.ToArray()); Warnings = @($warnings.ToArray())
}
Write-SetupJson -Value $manifest -Path (Join-Path $backup 'manifest.json')
$timer.Stop()
$result = if ($warnings.Count -gt 0) { 'BACKUP MIT WARNUNGEN ABGESCHLOSSEN' } else { 'BACKUP ABGESCHLOSSEN' }
$summary = @(
    $result
    "Sicherungsordner: $backup"
    ('Dauer: {0:hh\:mm\:ss}' -f $timer.Elapsed)
    "Programmeintraege im Inventar: $(@($programs).Count)"
    ('Store-App-Eintraege: ' + $(if ($null -ne $storeCount) { $storeCount } else { 'Export fehlgeschlagen' }))
    ('WinGet-Installationsliste: ' + $(if ($wingetReady) { "$packageCount Pakete exportiert" } else { 'NICHT verfuegbar' }))
    "Python/pip: $pythonStatus"
    "Gesicherte Dateien: $($files.Count)"
    "Registry-Einstellungen: $($registryValues.Count)"
    ('Startlayout: ' + $(if ($startLayoutReady) { 'exportiert; Pins manuell wiederherstellen' } else { 'NICHT exportiert' }))
    ('Entwicklereinstellungen: ' + $(if ($IncludeDeveloperSettings) { 'ausgewaehlt' } else { 'nicht ausgewaehlt' }))
    "Warnungen: $($warnings.Count)"
    'WinGet-Log auf nicht zugeordnete Programme pruefen: Export ist kein Vollstaendigkeitsnachweis.'
    'Vor einer Neuinstallation den abgeschlossenen OneDrive-Upload kontrollieren.'
)
$summaryPath = Join-Path $backup 'Zusammenfassung.txt'
@($summary; $warnings.ToArray()) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Progress -Id 1 -Activity 'Windows-Setup sichern' -Completed
Write-Host ''
$summaryColor = if ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' }
Write-BackupStatus $result -Color $summaryColor
foreach ($line in $summary | Select-Object -Skip 1) { Write-BackupStatus $line }
foreach ($warning in $warnings) { Write-BackupStatus "WARNUNG: $warning" -Color Yellow }
Write-BackupStatus "Abschlussbericht: $summaryPath"
[pscustomobject]@{ BackupPath = $backup; WingetReady = $wingetReady; StartLayoutReady = $startLayoutReady; WarningCount = $warnings.Count }
} catch {
    # Keep the original error even if writing the log also fails (e.g. disk full).
    $failure = "BACKUP ABGEBROCHEN: $($_.Exception.Message)"
    Write-Host $failure -ForegroundColor Red
    if ($backup) { Write-Host "Moeglicherweise unvollstaendige Sicherung: $backup" -ForegroundColor Yellow }
    if ($logPath) { Add-Content -LiteralPath $logPath -Value $failure -Encoding UTF8 -ErrorAction SilentlyContinue }
    throw
} finally {
    $timer.Stop()
    Write-Progress -Id 2 -Activity 'Dateien sichern' -Completed
    Write-Progress -Id 1 -Activity 'Windows-Setup sichern' -Completed
}

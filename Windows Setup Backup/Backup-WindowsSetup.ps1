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
    [switch]$SkipChocolatey,
    [string[]]$PythonExecutables = @(),
    [string[]]$CustomFolders = @(),
    [string[]]$ExcludedExtensions = @(),
    [switch]$CreateArchive,
    [string]$ArchivePassword = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
$timer = [Diagnostics.Stopwatch]::StartNew()
$logPath = $null
$stagingRoot = $null
$backup = $null
$finalPath = $null
$publishingPath = $null
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
$backupName = "$env:COMPUTERNAME-$stamp"
$destinationRoot = [IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Path $destinationRoot -Force -ErrorAction Stop | Out-Null
$finalBasePath = Join-Path $destinationRoot $backupName
$finalDisplayPath = if ($CreateArchive) { $finalBasePath + $(if ($ArchivePassword) { '.7z' } else { '.zip' }) } else { $finalBasePath }
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsSetupBackup-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $stagingRoot $backupName
New-Item -ItemType Directory -Path $backup -Force -ErrorAction Stop | Out-Null
$logPath = Join-Path $backup 'backup.log'
Write-BackupStatus "Temporärer Sicherungsordner: $backup"
Write-BackupStatus "Endgültiges Sicherungsziel: $finalDisplayPath"
Write-BackupStatus ('Entwicklereinstellungen: ' + $(if ($IncludeDeveloperSettings) { 'eingeschlossen' } else { 'nicht ausgewaehlt (optional: -IncludeDeveloperSettings)' }))
$warnings = [Collections.Generic.List[string]]::new()
$files = [Collections.Generic.List[object]]::new()
$wingetReady = $false
$startLayoutReady = $false
$packageCount = 0
$storeCount = $null
$pythonResult = $null
$pythonStatus = 'nicht gesichert'
$customFolderResults = [Collections.Generic.List[object]]::new()
$archivePath = $null
$extraResult = $null
$excluded = @($ExcludedExtensions | ForEach-Object {
    $value = $_.Trim().TrimStart('*')
    if ($value -and -not $value.StartsWith('.')) { $value = '.' + $value }
    if ($value) { $value.ToLowerInvariant() }
} | Where-Object { $_ } | Select-Object -Unique)
if ($ArchivePassword -and -not $CreateArchive) { throw 'Ein Archivpasswort erfordert -CreateArchive.' }
Assert-SetupArchivePassword $ArchivePassword

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
    $apps = @(Get-AppxPackage | Select-Object Name, Version, PackageFamilyName, PackageFullName, SignatureKind, IsFramework, IsResourcePackage, NonRemovable)
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
        foreach ($linkedDirectory in @(Get-ChildItem -LiteralPath $location.Path -Directory -Recurse:$recursive -Force -ErrorAction Stop | Where-Object LinkType)) {
            throw "Verknüpfter Quellordner wird nicht gesichert: $($linkedDirectory.FullName)"
        }
        $sourceFiles = @(Get-ChildItem -LiteralPath $location.Path -File -Recurse:$recursive -Force)
        $fileNumber = 0
        foreach ($file in $sourceFiles) {
            if ($file.LinkType -and $file.LinkType -ne 'HardLink') { Add-BackupWarning "Verknüpfte Quelldatei wurde ausgelassen: $($file.FullName)"; continue }
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
foreach ($source in @($CustomFolders | Select-Object -Unique)) {
    $source = [IO.Path]::GetFullPath($source)
    if ($source -ne [IO.Path]::GetPathRoot($source)) { $source = $source.TrimEnd('\') }
    $index = $customFolderResults.Count + 1
    $safeName = ([IO.Path]::GetFileName($source) -replace '[^a-zA-Z0-9._-]', '_')
    if (-not $safeName) { $safeName = 'Ordner' }
    $key = 'Custom{0:D2}' -f $index
    $storedRoot = 'Files\CustomFolders\{0:D2}_{1}' -f $index, $safeName
    $countBefore = $files.Count
    Write-BackupStatus "Benutzerdefinierter Ordner: $source"
    try {
        foreach ($linkedDirectory in @(Get-ChildItem -LiteralPath $source -Directory -Recurse -Force -ErrorAction Stop | Where-Object LinkType)) {
            throw "Verknüpfter Quellordner wird nicht gesichert: $($linkedDirectory.FullName)"
        }
        $sourceFiles = @(Get-ChildItem -LiteralPath $source -File -Recurse -Force -ErrorAction Stop)
        $relativeStart = if ($source.EndsWith('\')) { $source.Length } else { $source.Length + 1 }
        foreach ($file in $sourceFiles) {
            if ($file.LinkType) { Add-BackupWarning "Verknüpfte Quelldatei wurde ausgelassen: $($file.FullName)"; continue }
            $relative = $file.FullName.Substring($relativeStart)
            if ($excluded -contains $file.Extension.ToLowerInvariant()) { continue }
            try {
                $stored = "$storedRoot\$relative"
                $target = Join-SetupSafePath $backup $stored
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                $files.Add([pscustomobject]@{ Key = $key; Relative = $relative; Stored = $stored; SHA256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash })
            } catch { Add-BackupWarning "Datei nicht gesichert: $($file.FullName): $_" }
        }
    } catch { Add-BackupWarning "Benutzerdefinierter Ordner nicht vollstaendig gelesen: ${source}: $_" }
    $customFolderResults.Add([pscustomobject]@{ Key = $key; Source = $source; StoredRoot = $storedRoot; FileCount = $files.Count - $countBefore })
    Write-BackupStatus ("Benutzerdefinierter Ordner: {0} Dateien gesichert." -f ($files.Count - $countBefore))
}
try {
    Write-BackupStatus 'Zusätzliche System-, Entwickler- und Verbindungsinventare werden erstellt ...'
    $extraResult = & (Join-Path $PSScriptRoot 'Backup-SetupExtras.ps1') -BackupPath $backup -IncludeDeveloperSettings:$IncludeDeveloperSettings -SkipChocolatey:$SkipChocolatey
    foreach ($warning in @($extraResult.Warnings)) { Add-BackupWarning $warning }
} catch { Add-BackupWarning "Zusätzliche Inventare konnten nicht vollständig erstellt werden: $_" }
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
$payloadFiles = @(Get-ChildItem -LiteralPath $backup -File -Recurse -Force -ErrorAction Stop)
[long]$payloadBytes = 0
foreach ($payloadFile in $payloadFiles) {
    if ($payloadFile.Length -gt 20GB) { throw "Eine Sicherungsdatei überschreitet 20 GB: $($payloadFile.FullName)" }
    $payloadBytes += $payloadFile.Length
}
if ($payloadFiles.Count -gt 249999 -or $payloadBytes -gt 100GB) { throw 'Die Sicherung überschreitet die unterstützte Datei- oder Gesamtgröße.' }
$windows = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$manifest = [ordered]@{
    SchemaVersion = 1; ApplicationVersion = $script:SetupBackupVersion; Created = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME
    User = $env:USERNAME; OriginalProfile = $env:USERPROFILE
    Windows = @{ Edition = $windows.EditionID; Version = $windows.DisplayVersion; Build = $windows.CurrentBuild; UBR = $windows.UBR }
    WingetReady = $wingetReady; StartLayoutReady = $startLayoutReady
    Python = $pythonResult; PythonStatus = $pythonStatus; Extras = $extraResult
    DeveloperSettings = [bool]$IncludeDeveloperSettings; CustomFolders = @($customFolderResults.ToArray())
    ExcludedExtensions = @($excluded); Files = @($files.ToArray()); Warnings = @($warnings.ToArray())
}
Write-SetupJson -Value $manifest -Path (Join-Path $backup 'manifest.json')
$manifestItem = Get-Item -LiteralPath (Join-Path $backup 'manifest.json')
if ($manifestItem.Length -gt 16MB) { throw 'Das Sicherungsmanifest überschreitet 16 MB.' }
$timer.Stop()
$result = if ($warnings.Count -gt 0) { 'BACKUP MIT WARNUNGEN ABGESCHLOSSEN' } else { 'BACKUP ABGESCHLOSSEN' }
$summary = @(
    $result
    "Sicherungsziel: $finalDisplayPath"
    ('Dauer: {0:hh\:mm\:ss}' -f $timer.Elapsed)
    "Programmeintraege im Inventar: $(@($programs).Count)"
    ('Store-App-Eintraege: ' + $(if ($null -ne $storeCount) { $storeCount } else { 'Export fehlgeschlagen' }))
    ('WinGet-Installationsliste: ' + $(if ($wingetReady) { "$packageCount Pakete exportiert" } else { 'NICHT verfuegbar' }))
    "Python/pip: $pythonStatus"
    "Benutzerdefinierte Ordner: $($customFolderResults.Count)"
    "VS-Code-Erweiterungen / PowerShell-Module: $($extraResult.ExtensionCount) / $($extraResult.ModuleCount)"
    "Chocolatey-Pakete: $($extraResult.ChocolateyCount)"
    "Umgebungsvariablen / Windows-Komponenten: $($extraResult.EnvironmentCount) / $($extraResult.FeatureCount)"
    "Drucker / Netzlaufwerke: $($extraResult.PrinterCount) / $($extraResult.DriveCount)"
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
if ($CreateArchive) {
    Write-BackupStatus 'Sicherung wird gepackt ...'
    if ($ArchivePassword) {
        $sevenZipPath = Get-SetupSevenZipPath
        if (-not $sevenZipPath) { throw 'Fuer ein passwortgeschuetztes Archiv muss 7-Zip (7z.exe) installiert sein.' }
        $stagedArchive = Join-Path $stagingRoot "$backupName.7z"
        & $sevenZipPath a -t7z -mx=7 -mhe=on ("-p$ArchivePassword") $stagedArchive (Join-Path $backup '*') | ForEach-Object { Write-BackupStatus $_ }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stagedArchive)) { throw "7-Zip konnte das Archiv nicht erstellen (Exitcode $LASTEXITCODE)." }
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stagedArchive = Join-Path $stagingRoot "$backupName.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($backup, $stagedArchive, [IO.Compression.CompressionLevel]::Optimal, $false)
    }
    $archivePath = $finalDisplayPath
    $publishingPath = Join-Path $destinationRoot ('.wsb-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp')
    $logPath = $null
    Move-Item -LiteralPath $stagedArchive -Destination $publishingPath -ErrorAction Stop
    if ($ArchivePassword) {
        & $sevenZipPath t -y ("-p$ArchivePassword") $publishingPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Das übertragene 7z-Archiv konnte nicht abschließend validiert werden.' }
    } else {
        $publishedZip = [IO.Compression.ZipFile]::OpenRead($publishingPath)
        try {
            foreach ($publishedEntry in $publishedZip.Entries) {
                if ([string]::IsNullOrEmpty($publishedEntry.Name)) { continue }
                $entryStream = $publishedEntry.Open()
                try { $entryStream.CopyTo([IO.Stream]::Null) } finally { $entryStream.Dispose() }
            }
            $publishedManifestEntry = @($publishedZip.Entries | Where-Object FullName -eq 'manifest.json')
            if ($publishedManifestEntry.Count -ne 1) { throw 'Das übertragene ZIP-Archiv enthält kein eindeutiges Manifest.' }
            $reader = [IO.StreamReader]::new($publishedManifestEntry[0].Open(), [Text.Encoding]::UTF8, $true)
            try { $publishedManifest = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
            if ($publishedManifest.SchemaVersion -ne 1 -or $publishedManifest.Computer -ne $env:COMPUTERNAME) { throw 'Das übertragene ZIP-Archiv konnte nicht abschließend validiert werden.' }
        } finally { $publishedZip.Dispose() }
    }
    Move-Item -LiteralPath $publishingPath -Destination $archivePath -ErrorAction Stop
    $publishingPath = $null
    $finalPath = $archivePath
    Write-BackupStatus "Archiv ins Sicherungsziel verschoben: $archivePath" -Color Green
} else {
    $publishingPath = Join-Path $destinationRoot ('.wsb-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $logPath = $null
    $sourceInventory = @(Get-ChildItem -LiteralPath $backup -File -Recurse -Force -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Relative = $_.FullName.Substring($backup.TrimEnd('\').Length + 1); Length = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    Move-Item -LiteralPath $backup -Destination $publishingPath -ErrorAction Stop
    $publishedManifest = Get-Content -LiteralPath (Join-Path $publishingPath 'manifest.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($publishedManifest.SchemaVersion -ne 1 -or $publishedManifest.Computer -ne $env:COMPUTERNAME) { throw 'Der übertragene Sicherungsordner konnte nicht abschließend validiert werden.' }
    foreach ($file in $sourceInventory) {
        $publishedFile = Join-SetupSafePath $publishingPath $file.Relative
        $publishedItem = Get-Item -LiteralPath $publishedFile -ErrorAction Stop
        if ($publishedItem.Length -ne $file.Length -or (Get-FileHash -LiteralPath $publishedFile -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Übertragene Datei hat eine falsche Prüfsumme: $publishedFile" }
    }
    Move-Item -LiteralPath $publishingPath -Destination $finalBasePath -ErrorAction Stop
    $publishingPath = $null
    $finalPath = $finalBasePath
    Write-BackupStatus "Sicherungsordner ins Ziel verschoben: $finalPath" -Color Green
}
Write-Progress -Id 1 -Activity 'Windows-Setup sichern' -Completed
Write-Host ''
$summaryColor = if ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' }
Write-BackupStatus $result -Color $summaryColor
foreach ($line in $summary | Select-Object -Skip 1) { Write-BackupStatus $line }
foreach ($warning in $warnings) { Write-BackupStatus "WARNUNG: $warning" -Color Yellow }
Write-BackupStatus "Abschlussbericht: $(if ($CreateArchive) { 'im Archiv' } else { Join-Path $finalPath 'Zusammenfassung.txt' })"
[pscustomobject]@{ BackupPath = $finalPath; ArchivePath = $archivePath; WingetReady = $wingetReady; StartLayoutReady = $startLayoutReady; WarningCount = $warnings.Count }
} catch {
    # Keep the original error even if writing the log also fails (e.g. disk full).
    $failure = "BACKUP ABGEBROCHEN: $($_.Exception.Message)"
    Write-Host $failure -ForegroundColor Red
    if ($backup -and (Test-Path -LiteralPath $backup)) { Write-Host "Temporäre, möglicherweise unvollständige Sicherung wird entfernt: $backup" -ForegroundColor Yellow }
    if ($logPath) { Add-Content -LiteralPath $logPath -Value $failure -Encoding UTF8 -ErrorAction SilentlyContinue }
    throw
} finally {
    $timer.Stop()
    if ($publishingPath -and (Test-Path -LiteralPath $publishingPath)) { Remove-Item -LiteralPath $publishingPath -Recurse -Force -ErrorAction SilentlyContinue }
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Progress -Id 2 -Activity 'Dateien sichern' -Completed
    Write-Progress -Id 1 -Activity 'Windows-Setup sichern' -Completed
}

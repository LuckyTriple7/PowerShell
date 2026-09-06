#requires -Version 5.1
# Data and validation shared by the GUI and its background worker.
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
function Read-SetupDocument {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Save-SetupDocument {
    param($Value, [string]$Path)
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    ConvertTo-Json -InputObject $Value -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}

function Get-SetupAbsoluteDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '["\r\n]') { throw 'Bitte einen gültigen absoluten Ordnerpfad angeben.' }
    if ($Path -notmatch '^([a-zA-Z]:[\\/]|\\\\[^\\]+\\[^\\]+)') { throw 'Ein absoluter Pfad ist erforderlich, zum Beispiel C:\Backups.' }
    [IO.Path]::GetFullPath($Path.Trim())
}

function Protect-SetupSecret {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    ConvertFrom-SecureString (ConvertTo-SecureString $Value -AsPlainText -Force)
}

function Unprotect-SetupSecret {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $secure = ConvertTo-SecureString $Value
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Read-SetupZipDocument {
    param([string]$ArchivePath, [string]$EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $normalized = $EntryName.Replace('\','/')
        $entry = @($archive.Entries | Where-Object { $_.FullName.Replace('\','/') -eq $normalized })
        if ($entry.Count -ne 1) { throw "Datei fehlt im ZIP-Backup: $EntryName" }
        $reader = [IO.StreamReader]::new($entry[0].Open(), [Text.Encoding]::UTF8, $true)
        try { $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}

function Read-SetupBackupDocument {
    param([string]$BackupPath, [string]$RelativePath)
    if (Test-Path -LiteralPath $BackupPath -PathType Container) { return Read-SetupDocument (Join-Path $BackupPath $RelativePath) }
    if ([IO.Path]::GetExtension($BackupPath) -ieq '.zip' -and (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        return Read-SetupZipDocument $BackupPath $RelativePath
    }
    throw "Ungültige Backup-Quelle: $BackupPath"
}

function Test-SetupBackupDocument {
    param([string]$BackupPath, [string]$RelativePath)
    try { $null = Read-SetupBackupDocument $BackupPath $RelativePath; return $true } catch { return $false }
}

function Expand-SetupZipBackup {
    param([string]$ArchivePath, [string]$Destination)
    if ([IO.Path]::GetExtension($ArchivePath) -ine '.zip') { throw 'Nur ZIP-Backups können automatisch entpackt werden.' }
    if (Test-Path -LiteralPath $Destination) { throw "Entpackziel existiert bereits: $Destination" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
        $base = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $base $entry.FullName.Replace('/','\')))
            if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "ZIP-Eintrag verlässt das Zielverzeichnis: $($entry.FullName)" }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
        $manifest = Read-SetupDocument (Join-Path $Destination 'manifest.json')
        if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion im ZIP-Backup.' }
    } catch {
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally { $archive.Dispose() }
    return $Destination
}

function Get-SetupBackupEntries {
    param([string]$Root)
    $source = Get-SetupAbsoluteDirectory $Root
    $sources = @()
    if (Test-Path -LiteralPath $source -PathType Container) {
        $sources += @($source)
        $sources += @(Get-ChildItem -LiteralPath $source -Directory -ErrorAction Stop | Select-Object -ExpandProperty FullName)
        foreach ($zip in @(Get-ChildItem -LiteralPath $source -File -Filter '*.zip' -ErrorAction Stop)) {
            $folderPath = [IO.Path]::Combine($zip.DirectoryName, [IO.Path]::GetFileNameWithoutExtension($zip.Name))
            if (-not (Test-Path -LiteralPath (Join-Path $folderPath 'manifest.json') -PathType Leaf)) { $sources += $zip.FullName }
        }
    } elseif ((Test-Path -LiteralPath $source -PathType Leaf) -and [IO.Path]::GetExtension($source) -ieq '.zip') {
        $sources += $source
    } else { throw "Backup-Quelle nicht gefunden: $source" }
    foreach ($folder in $sources) {
        $isArchive = [IO.Path]::GetExtension($folder) -ieq '.zip'
        if (-not $isArchive -and -not (Test-Path -LiteralPath (Join-Path $folder 'manifest.json') -PathType Leaf)) { continue }
        try {
            $manifest = Read-SetupBackupDocument $folder 'manifest.json'
            if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
            $python = @()
            try {
                $pythonDocument = Read-SetupBackupDocument $folder 'Python\environments.json'
                if ($pythonDocument.SchemaVersion -ne 1) { throw 'Unbekannte Python-Sicherungsversion.' }
                $python = @($pythonDocument.Environments | Where-Object Status -eq 'Exported')
            } catch { if ($_.Exception.Message -notlike 'Datei fehlt im ZIP-Backup:*' -and $isArchive) { throw } }
            [pscustomobject]@{
                Path = $folder; Created = ([datetime]$manifest.Created).ToLocalTime(); Computer = $manifest.Computer
                Winget = [bool]$manifest.WingetReady; Python = $python; Files = @($manifest.Files).Count
                Warnings = @($manifest.Warnings); Manifest = $manifest; IsArchive = $isArchive; Error = $null
            }
        } catch {
            [pscustomobject]@{ Path = $folder; Created = [datetime]::MinValue; Computer = '?'; Winget = $false
                Python = @(); Files = 0; Warnings = @(); Manifest = $null; IsArchive = $isArchive; Error = $_.Exception.Message }
        }
    }
}

function Remove-SetupBackup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$BackupPath, [Parameter(Mandatory)][string]$SourceRoot)
    $ErrorActionPreference = 'Stop'
    $source = (Get-SetupAbsoluteDirectory $SourceRoot).TrimEnd('\')
    $target = (Get-SetupAbsoluteDirectory $BackupPath).TrimEnd('\')
    $sourceItem = Get-Item -LiteralPath $source -Force
    # Only the selected backup itself or a direct child of the displayed source.
    if ($target -ne $source -and (-not $sourceItem.PSIsContainer -or (Split-Path -Path $target -Parent).TrimEnd('\') -ne $source)) {
        throw 'Die ausgewählte Sicherung liegt außerhalb der angezeigten Backup-Quelle.'
    }
    $item = Get-Item -LiteralPath $target -Force
    if ($item.LinkType) { throw 'Verknüpfte Dateien oder Ordner werden nicht automatisch gelöscht.' }
    $isArchive = -not $item.PSIsContainer -and $item.Extension -ieq '.zip'
    if (-not $item.PSIsContainer -and -not $isArchive) { throw 'Das Löschziel muss ein Backup-Ordner oder ZIP-Backup sein.' }
    $manifest = Read-SetupBackupDocument $target 'manifest.json'
    if ($manifest.SchemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($manifest.Computer)) { throw 'Keine gültige Sicherung.' }
    $suffix = if ($isArchive) { '\.zip' } else { '' }
    $expectedName = '^' + [regex]::Escape($manifest.Computer) + '-\d{8}-\d{6}-\d{3}' + $suffix + '$'
    if ($item.Name -notmatch $expectedName) { throw 'Der Name entspricht keiner erzeugten Sicherung. Sie wird nicht automatisch gelöscht.' }
    $mutex = [Threading.Mutex]::new($false, ('Local\WindowsSetupBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Eine Sicherung oder Wiederherstellung läuft bereits. Bitte später löschen.' }
        $action = if ($isArchive) { 'Ausgewähltes ZIP-Backup dauerhaft löschen' } else { 'Ausgewählten Backup-Ordner dauerhaft löschen' }
        if ($PSCmdlet.ShouldProcess($target, $action)) {
            if ($isArchive) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-SetupRequest {
    param($Request)
    if ($Request.SchemaVersion -ne 1) { throw 'Unbekannte Auftragsversion.' }
    if ($Request.Operation -notin @('Backup','Restore')) { throw 'Unbekannte Aktion.' }
    if ($Request.Operation -eq 'Backup') {
        $destination = Get-SetupAbsoluteDirectory $Request.Destination
        foreach ($python in @($Request.PythonExecutables)) {
            if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "Zusätzlicher Python-Interpreter fehlt: $python" }
        }
        foreach ($folder in @($Request.CustomFolders)) {
            $custom = Get-SetupAbsoluteDirectory $folder
            if (-not (Test-Path -LiteralPath $custom -PathType Container)) { throw "Benutzerdefinierter Ordner fehlt: $custom" }
            if (($destination.TrimEnd('\') + '\').StartsWith(($custom.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                throw "Das Sicherungsziel darf nicht innerhalb eines benutzerdefinierten Ordners liegen: $custom"
            }
        }
        foreach ($extension in @($Request.ExcludedExtensions)) {
            if ($extension -notmatch '^\.?[a-zA-Z0-9_-]+$') { throw "Ungültige auszuschließende Dateiendung: $extension" }
        }
        if (-not [string]::IsNullOrEmpty([string]$Request.ProtectedArchivePassword) -and -not [bool]$Request.CreateArchive) {
            throw 'Ein Archivpasswort erfordert die Option Archiv erstellen.'
        }
    } else {
        $root = Get-SetupAbsoluteDirectory $Request.BackupPath
        $manifest = Read-SetupBackupDocument $root 'manifest.json'
        if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
        $customFolderKeys = @($Request.CustomFolderKeys | Where-Object { $_ })
        $storePackageFamilies = @($Request.StorePackageFamilies | Where-Object { $_ })
        $chocolateyPackages = @($Request.ChocolateyPackages | Where-Object { $_ })
        $extrasSelected = $customFolderKeys.Count -gt 0 -or $Request.VSCodeExtensions -or $Request.PowerShellModules -or
            $Request.UserEnvironment -or $Request.MachineEnvironment -or $Request.WindowsComponents -or $Request.Connections -or
            $storePackageFamilies.Count -gt 0 -or $chocolateyPackages.Count -gt 0
        if (-not ($Request.Programs -or $Request.Settings -or $Request.Shortcuts -or $Request.PythonPackages -or $extrasSelected)) { throw 'Mindestens einen Bestandteil zur Wiederherstellung auswählen.' }
        if ($Request.Programs -and -not $manifest.WingetReady) { throw 'Dieser Sicherung fehlt eine verwendbare WinGet-Liste.' }
        if ($Request.IncludeCommonStartMenu -and -not $Request.Shortcuts) { throw 'Gemeinsames Startmenü erfordert Startmenü-Verknüpfungen.' }
        if ($Request.IncludeCommonStartMenu -and -not $Request.Preview) {
            $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'Für das gemeinsame Startmenü die GUI als Administrator mit demselben Benutzerkonto starten oder diese Option abwählen.'
            }
        }
        if (($Request.MachineEnvironment -or $Request.WindowsComponents) -and -not $Request.Preview) {
            $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'System-Umgebungsvariablen und Windows-Komponenten erfordern eine als Administrator gestartete GUI.'
            }
        }
        foreach ($key in $customFolderKeys) {
            if (@($manifest.CustomFolders | Where-Object Key -eq $key).Count -ne 1) { throw "Unbekannter benutzerdefinierter Ordner: $key" }
        }
        if ($chocolateyPackages.Count -gt 0) {
            if (-not (Test-SetupBackupDocument $root 'package-managers.json')) { throw 'Diese Sicherung enthält kein Chocolatey-Inventar.' }
            $managerData = Read-SetupBackupDocument $root 'package-managers.json'
            $availableChocolatey = @($managerData.Chocolatey.Packages | ForEach-Object { [string]$_.Id })
            foreach ($id in $chocolateyPackages) { if ($availableChocolatey -notcontains $id) { throw "Unbekanntes Chocolatey-Paket: $id" } }
        }
        if ($storePackageFamilies.Count -gt 0) {
            if (-not (Test-SetupBackupDocument $root 'store-apps.json')) { throw 'Diese Sicherung enthält kein Store-App-Inventar.' }
            $storeDocument = Read-SetupBackupDocument $root 'store-apps.json'
            $availableFamilies = @($storeDocument.GetEnumerator() | ForEach-Object { [string]$_.PackageFamilyName })
            foreach ($family in $storePackageFamilies) { if ($availableFamilies -notcontains $family) { throw "Unbekannte Store-App: $family" } }
        }
        if ($Request.PythonPackages) {
            if ($Request.EnvironmentId -notmatch '^python-[0-9]+$') { throw 'Eine gesicherte pip-Umgebung auswählen.' }
            if (-not (Test-Path -LiteralPath $Request.PythonExecutable -PathType Leaf)) { throw 'Vorhandene python.exe als Wiederherstellungsziel auswählen.' }
            $python = Read-SetupBackupDocument $root 'Python\environments.json'
            $matches = @($python.Environments | Where-Object { $_.Id -eq $Request.EnvironmentId -and $_.Status -eq 'Exported' })
            if ($python.SchemaVersion -ne 1 -or $matches.Count -ne 1) { throw 'Die ausgewählte pip-Umgebung ist nicht wiederherstellbar.' }
        }
    }
}

function Get-SetupTaskName {
    'WindowsSetupBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-SetupTaskArguments {
    param([string]$WorkerPath, [string]$RequestPath)
    foreach ($path in @($WorkerPath, $RequestPath)) {
        if ($path -match '["\r\n]') { throw 'Ungültiger Pfad für die Aufgabenplanung.' }
    }
    '-NoProfile -NonInteractive -WindowStyle Hidden -File "{0}" -RequestPath "{1}"' -f $WorkerPath, $RequestPath
}

function Get-ManagedSetupTask {
    $task = Get-ScheduledTask -TaskName (Get-SetupTaskName) -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task -and $task.Description -notlike 'Windows Setup Backup GUI;*') {
        throw 'Unter diesem Namen existiert eine fremde Aufgabe. Sie wird nicht geändert.'
    }
    return $task
}

function Register-SetupBackupTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$WorkerPath, [string]$RequestPath,
        [ValidateSet('Daily','Weekly')][string]$Frequency,
        [datetime]$Time,
        [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string]$Day,
        [switch]$AllowBattery
    )
    $null = Get-ManagedSetupTask
    $request = Read-SetupDocument $RequestPath
    Test-SetupRequest $request
    if ($request.Operation -ne 'Backup') { throw 'Geplant werden ausschließlich Sicherungen.' }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument (Get-SetupTaskArguments $WorkerPath $RequestPath) -WorkingDirectory (Split-Path $WorkerPath -Parent)
    $trigger = if ($Frequency -eq 'Daily') { New-ScheduledTaskTrigger -Daily -At $Time } else { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Time }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $options = @{ StartWhenAvailable = $true; MultipleInstances = 'IgnoreNew'; ExecutionTimeLimit = [timespan]::FromHours(4) }
    if ($AllowBattery) { $options.AllowStartIfOnBatteries = $true; $options.DontStopIfGoingOnBatteries = $true }
    $settings = New-ScheduledTaskSettingsSet @options
    if ($PSCmdlet.ShouldProcess((Get-SetupTaskName), 'Geplante Sicherung anlegen oder aktualisieren')) {
        Register-ScheduledTask -TaskName (Get-SetupTaskName) -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Windows Setup Backup GUI; Benutzer: $user; Konfiguration: $RequestPath" -Force -ErrorAction Stop | Out-Null
    }
}

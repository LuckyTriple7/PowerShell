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
        if ($entry[0].Length -gt 16MB) { throw "Dokument im ZIP-Backup ist zu groß: $EntryName" }
        $reader = [IO.StreamReader]::new($entry[0].Open(), [Text.Encoding]::UTF8, $true)
        try { $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}

function Read-SetupSevenZipDocument {
    param([string]$ArchivePath, [string]$EntryName, [string]$ArchivePassword)
    $sevenZipPath = Get-SetupSevenZipPath
    if (-not $sevenZipPath) { throw 'Zum Lesen eines 7z-Backups muss 7-Zip installiert sein.' }
    $output = @(& $sevenZipPath e -so -y ("-p$ArchivePassword") $ArchivePath $EntryName 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim() }) -join ' '
        throw "7z-Backup konnte nicht gelesen werden. Passwort prüfen. $detail"
    }
    $json = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($json)) { throw "Datei fehlt im 7z-Backup: $EntryName" }
    if ($json.Length -gt 16MB) { throw "Dokument im 7z-Backup ist zu groß: $EntryName" }
    $json | ConvertFrom-Json -ErrorAction Stop
}

function Assert-SetupArchiveEntryPath {
    param([string]$EntryName, [string]$Destination)
    if ([string]::IsNullOrWhiteSpace($EntryName) -or [IO.Path]::IsPathRooted($EntryName) -or $EntryName.Contains(':')) {
        throw "Ungültiger Pfad im Backup-Archiv: $EntryName"
    }
    $base = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath((Join-Path $base $EntryName.Replace('/','\')))
    if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Archiveintrag verlässt das Zielverzeichnis: $EntryName" }
}

function Assert-SetupExtractionCapacity {
    param([long]$RequiredBytes, [string]$Destination)
    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination))
        $drive = [IO.DriveInfo]::new($root)
        if ($drive.IsReady -and $RequiredBytes + 512MB -gt $drive.AvailableFreeSpace) {
            throw "Nicht genügend freier Speicher zum Entpacken. Benötigt: $RequiredBytes Bytes; verfügbar: $($drive.AvailableFreeSpace) Bytes."
        }
    } catch [System.Management.Automation.RuntimeException] { throw }
    catch { }
}

function Assert-SetupSevenZipLimits {
    param([string]$ArchivePath, [string]$Destination, [string]$ArchivePassword)
    $sevenZipPath = Get-SetupSevenZipPath
    if (-not $sevenZipPath) { throw 'Zum Prüfen eines 7z-Backups muss 7-Zip installiert sein.' }
    $lines = @(& $sevenZipPath l -slt -ba -y ("-p$ArchivePassword") $ArchivePath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw '7z-Backup konnte nicht geprüft werden. Passwort und Archiv prüfen.' }
    $count = 0; [long]$total = 0
    foreach ($line in $lines) {
        $text = $line.ToString()
        if ($text -match '^Path = (.+)$') { $count++; Assert-SetupArchiveEntryPath $Matches[1] $Destination }
        elseif ($text -match '^Size = (\d+)$') {
            $size = [long]$Matches[1]
            if ($size -gt 20GB) { throw 'Ein einzelner 7z-Eintrag überschreitet 20 GB.' }
            $total += $size
        } elseif ($text -match '^(Symbolic Link|Hard Link) = ') { throw 'Verknüpfungen in 7z-Backups werden nicht entpackt.' }
        if ($count -gt 250000 -or $total -gt 100GB) { throw 'Das 7z-Backup überschreitet die zulässige Datei- oder Gesamtgröße.' }
    }
    if ($count -eq 0) { throw 'Das 7z-Backup enthält keine Dateien.' }
    Assert-SetupExtractionCapacity $total $Destination
}

function Read-SetupBackupDocument {
    param([string]$BackupPath, [string]$RelativePath, [string]$ArchivePassword = '')
    if (Test-Path -LiteralPath $BackupPath -PathType Container) { return Read-SetupDocument (Join-Path $BackupPath $RelativePath) }
    if ([IO.Path]::GetExtension($BackupPath) -ieq '.zip' -and (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        return Read-SetupZipDocument $BackupPath $RelativePath
    }
    if ([IO.Path]::GetExtension($BackupPath) -ieq '.7z' -and (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        return Read-SetupSevenZipDocument $BackupPath $RelativePath $ArchivePassword
    }
    throw "Ungültige Backup-Quelle: $BackupPath"
}

function Test-SetupBackupDocument {
    param([string]$BackupPath, [string]$RelativePath, [string]$ArchivePassword = '')
    try { $null = Read-SetupBackupDocument $BackupPath $RelativePath $ArchivePassword; return $true } catch { return $false }
}

function Read-SetupOptionalBackupDocument {
    param([string]$BackupPath, [string]$RelativePath, [string]$ArchivePassword = '')
    if ((Test-Path -LiteralPath $BackupPath -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $BackupPath $RelativePath) -PathType Leaf)) { return $null }
    try { Read-SetupBackupDocument $BackupPath $RelativePath $ArchivePassword }
    catch {
        if ($_.Exception.Message -like 'Datei fehlt im *-Backup:*') { return $null }
        throw
    }
}

function Expand-SetupZipBackup {
    param([string]$ArchivePath, [string]$Destination)
    if ([IO.Path]::GetExtension($ArchivePath) -ine '.zip') { throw 'Nur ZIP-Backups können automatisch entpackt werden.' }
    if (Test-Path -LiteralPath $Destination) { throw "Entpackziel existiert bereits: $Destination" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        [long]$total = 0; $count = 0
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $count++; $total += $entry.Length
            Assert-SetupArchiveEntryPath $entry.FullName $Destination
            if ($entry.Length -gt 20GB -or $count -gt 250000 -or $total -gt 100GB) { throw 'Das ZIP-Backup überschreitet die zulässige Datei- oder Gesamtgröße.' }
        }
        Assert-SetupExtractionCapacity $total $Destination
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

function Expand-SetupSevenZipBackup {
    param([string]$ArchivePath, [string]$Destination, [string]$ArchivePassword)
    if ([IO.Path]::GetExtension($ArchivePath) -ine '.7z') { throw 'Die Quelle ist kein 7z-Backup.' }
    if (Test-Path -LiteralPath $Destination) { throw "Entpackziel existiert bereits: $Destination" }
    $sevenZipPath = Get-SetupSevenZipPath
    if (-not $sevenZipPath) { throw 'Zum Entpacken eines 7z-Backups muss 7-Zip installiert sein.' }
    try {
        $archiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
        Assert-SetupSevenZipLimits $ArchivePath $Destination $ArchivePassword
        if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $archiveHash) { throw 'Das 7z-Backup wurde während der Prüfung verändert.' }
        New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
        & $sevenZipPath x -y ("-p$ArchivePassword") ("-o$Destination") $ArchivePath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '7-Zip konnte das Backup nicht entpacken. Passwort und Archiv prüfen.' }
        $manifest = Read-SetupDocument (Join-Path $Destination 'manifest.json')
        if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion im 7z-Backup.' }
    } catch {
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    return $Destination
}

function Get-SetupBackupEntries {
    param([string]$Root, [string]$ArchivePassword = '')
    $source = Get-SetupAbsoluteDirectory $Root
    $sources = @()
    if (Test-Path -LiteralPath $source -PathType Container) {
        $sources += @($source)
        $sources += @(Get-ChildItem -LiteralPath $source -Directory -ErrorAction Stop | Select-Object -ExpandProperty FullName)
        $sources += @(Get-ChildItem -LiteralPath $source -File -ErrorAction Stop | Where-Object Extension -in @('.zip','.7z') | Select-Object -ExpandProperty FullName)
    } elseif ((Test-Path -LiteralPath $source -PathType Leaf) -and [IO.Path]::GetExtension($source) -in @('.zip','.7z')) {
        $sources += $source
    } else { throw "Backup-Quelle nicht gefunden: $source" }
    foreach ($folder in $sources) {
        $archiveType = [IO.Path]::GetExtension($folder).TrimStart('.').ToUpperInvariant()
        $isArchive = $archiveType -in @('ZIP','7Z')
        if (-not $isArchive -and -not (Test-Path -LiteralPath (Join-Path $folder 'manifest.json') -PathType Leaf)) { continue }
        try {
            $manifest = Read-SetupBackupDocument $folder 'manifest.json' $ArchivePassword
            if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
            $python = @()
            $pythonDocument = Read-SetupOptionalBackupDocument $folder 'Python\environments.json' $ArchivePassword
            if ($pythonDocument) {
                if ($pythonDocument.SchemaVersion -ne 1) { throw 'Unbekannte Python-Sicherungsversion.' }
                $python = @($pythonDocument.Environments | Where-Object Status -eq 'Exported')
            }
            [pscustomobject]@{
                Path = $folder; Created = ([datetime]$manifest.Created).ToLocalTime(); Computer = $manifest.Computer
                Winget = [bool]$manifest.WingetReady; Python = $python; Files = @($manifest.Files).Count
                Warnings = @($manifest.Warnings); Manifest = $manifest; IsArchive = $isArchive; ArchiveType = $archiveType; Error = $null
            }
        } catch {
            [pscustomobject]@{ Path = $folder; Created = [datetime]::MinValue; Computer = '?'; Winget = $false
                Python = @(); Files = 0; Warnings = @(); Manifest = $null; IsArchive = $isArchive; ArchiveType = $archiveType; Error = $_.Exception.Message }
        }
    }
}

function Remove-SetupBackup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$BackupPath, [Parameter(Mandatory)][string]$SourceRoot, [string]$ArchivePassword = '')
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
    $isArchive = -not $item.PSIsContainer -and $item.Extension -in @('.zip','.7z')
    if (-not $item.PSIsContainer -and -not $isArchive) { throw 'Das Löschziel muss ein Backup-Ordner, ZIP- oder 7z-Backup sein.' }
    $manifest = Read-SetupBackupDocument $target 'manifest.json' $ArchivePassword
    if ($manifest.SchemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($manifest.Computer)) { throw 'Keine gültige Sicherung.' }
    $suffix = if ($isArchive) { [regex]::Escape($item.Extension) } else { '' }
    $expectedName = '^' + [regex]::Escape($manifest.Computer) + '-\d{8}-\d{6}-\d{3}' + $suffix + '$'
    if ($item.Name -notmatch $expectedName) { throw 'Der Name entspricht keiner erzeugten Sicherung. Sie wird nicht automatisch gelöscht.' }
    $mutex = [Threading.Mutex]::new($false, ('Local\WindowsSetupBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Eine Sicherung oder Wiederherstellung läuft bereits. Bitte später löschen.' }
        $action = if ($isArchive) { 'Ausgewähltes Archiv-Backup dauerhaft löschen' } else { 'Ausgewählten Backup-Ordner dauerhaft löschen' }
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
    $booleanFields = if ($Request.Operation -eq 'Backup') {
        @('IncludeDeveloperSettings','SkipWinget','SkipPython','SkipChocolatey','AcceptSourceAgreements','CreateArchive')
    } else {
        @('Preview','Programs','Settings','Shortcuts','IncludeCommonStartMenu','UseSavedVersions','AcceptAgreements','PythonPackages',
            'VSCodeExtensions','PowerShellModules','UserEnvironment','MachineEnvironment','WindowsComponents','Connections')
    }
    foreach ($name in $booleanFields) {
        $property = $Request.PSObject.Properties[$name]
        if ($Request.Operation -eq 'Restore' -and (-not $property -or $null -eq $property.Value)) { throw "Boolesches Pflichtfeld fehlt im Wiederherstellungsauftrag: $name" }
        if ($property -and $null -eq $property.Value) { throw "Auftragsfeld muss true oder false sein: $name" }
        if ($property -and $null -ne $property.Value -and $property.Value -isnot [bool]) { throw "Auftragsfeld muss true oder false sein: $name" }
    }
    if ($Request.Operation -eq 'Backup') {
        $destination = Get-SetupAbsoluteDirectory $Request.Destination
        foreach ($python in @($Request.PythonExecutables | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "Zusätzlicher Python-Interpreter fehlt: $python" }
        }
        foreach ($folder in @($Request.CustomFolders | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $custom = Get-SetupAbsoluteDirectory $folder
            if (-not (Test-Path -LiteralPath $custom -PathType Container)) { throw "Benutzerdefinierter Ordner fehlt: $custom" }
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if ($tempRoot.StartsWith(($custom.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "Der Windows-Temp-Ordner darf nicht innerhalb eines benutzerdefinierten Sicherungsordners liegen: $custom" }
            if (($destination.TrimEnd('\') + '\').StartsWith(($custom.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                throw "Das Sicherungsziel darf nicht innerhalb eines benutzerdefinierten Ordners liegen: $custom"
            }
        }
        foreach ($extension in @($Request.ExcludedExtensions | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if ($extension -notmatch '^\.?[a-zA-Z0-9_-]+$') { throw "Ungültige auszuschließende Dateiendung: $extension" }
        }
        if (-not [string]::IsNullOrEmpty([string]$Request.ProtectedArchivePassword) -and $Request.PSObject.Properties['CreateArchive'] -and -not [bool]$Request.CreateArchive) {
            throw 'Ein Archivpasswort erfordert die Option Archiv erstellen.'
        }
        Assert-SetupArchivePassword (Unprotect-SetupSecret ([string]$Request.ProtectedArchivePassword))
    } else {
        $root = Get-SetupAbsoluteDirectory $Request.BackupPath
        $archivePassword = Unprotect-SetupSecret ([string]$Request.ProtectedArchivePassword)
        $manifest = Read-SetupBackupDocument $root 'manifest.json' $archivePassword
        if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
        $customFolderKeys = [string[]]@($Request.CustomFolderKeys | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $storePackageFamilies = [string[]]@($Request.StorePackageFamilies | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $chocolateyPackages = [string[]]@($Request.ChocolateyPackages | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
            if (-not (Test-SetupBackupDocument $root 'package-managers.json' $archivePassword)) { throw 'Diese Sicherung enthält kein Chocolatey-Inventar.' }
            $managerData = Read-SetupBackupDocument $root 'package-managers.json' $archivePassword
            $availableChocolatey = @($managerData.Chocolatey.Packages | ForEach-Object { [string]$_.Id })
            foreach ($id in $chocolateyPackages) { if ($availableChocolatey -notcontains $id) { throw "Unbekanntes Chocolatey-Paket: $id" } }
        }
        if ($storePackageFamilies.Count -gt 0) {
            if (-not (Test-SetupBackupDocument $root 'store-apps.json' $archivePassword)) { throw 'Diese Sicherung enthält kein Store-App-Inventar.' }
            $storeDocument = Read-SetupBackupDocument $root 'store-apps.json' $archivePassword
            $availableFamilies = @($storeDocument.GetEnumerator() | ForEach-Object { [string]$_.PackageFamilyName })
            foreach ($family in $storePackageFamilies) { if ($availableFamilies -notcontains $family) { throw "Unbekannte Store-App: $family" } }
        }
        if ($Request.PythonPackages) {
            if ($Request.EnvironmentId -notmatch '^python-[0-9]+$') { throw 'Eine gesicherte pip-Umgebung auswählen.' }
            if (-not (Test-Path -LiteralPath $Request.PythonExecutable -PathType Leaf)) { throw 'Vorhandene python.exe als Wiederherstellungsziel auswählen.' }
            $python = Read-SetupBackupDocument $root 'Python\environments.json' $archivePassword
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

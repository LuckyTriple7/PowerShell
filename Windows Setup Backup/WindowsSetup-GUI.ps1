#requires -Version 5.1
<#
.SYNOPSIS
Grafische Oberfläche für Windows-Setup-Backups, Restore und geplante Sicherungen.
#>
[CmdletBinding()]
param([switch]$ValidateOnly, [string]$ValidationBackupRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'WindowsSetup.GuiSupport.ps1')
$stateRoot = Join-Path $PSScriptRoot 'GuiState'
$settingsPath = Join-Path $stateRoot 'settings.json'
$workerPath = Join-Path $PSScriptRoot 'Invoke-WindowsSetupJob.ps1'
$script:operation = $null
$script:selectedBackup = $null
$script:lastRun = $null
$script:lastLogLength = -1

function New-UiButton {
    param([string]$Text, [int]$Width = 145)
    $control = [Windows.Forms.Button]::new()
    $control.Text = $Text; $control.Width = $Width; $control.Height = 32
    $control.FlatStyle = 'System'; $control.Margin = [Windows.Forms.Padding]::new(4)
    return $control
}
function New-UiCheck {
    param([string]$Text, [bool]$Checked = $false)
    $control = [Windows.Forms.CheckBox]::new()
    $control.Text = $Text; $control.AutoSize = $true; $control.Checked = $Checked
    $control.Margin = [Windows.Forms.Padding]::new(4,8,16,4)
    return $control
}
function New-UiLabel {
    param([string]$Text)
    $control = [Windows.Forms.Label]::new()
    $control.Text = $Text; $control.Dock = 'Fill'; $control.TextAlign = 'MiddleLeft'
    return $control
}
function New-UiFlow {
    $panel = [Windows.Forms.FlowLayoutPanel]::new()
    $panel.Dock = 'Fill'; $panel.WrapContents = $true
    $panel.AutoSize = $true; $panel.AutoSizeMode = 'GrowAndShrink'
    return $panel
}
function New-UiTable {
    param([int[]]$Heights)
    $panel = [Windows.Forms.TableLayoutPanel]::new()
    $panel.Dock = 'Top'; $panel.AutoSize = $true; $panel.ColumnCount = 3
    $panel.Padding = [Windows.Forms.Padding]::new(12)
    [void]$panel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute,155))
    [void]$panel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
    [void]$panel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute,115))
    foreach ($height in $Heights) {
        $sizeType = if ($height -eq 0) { [Windows.Forms.SizeType]::AutoSize } else { [Windows.Forms.SizeType]::Absolute }
        [void]$panel.RowStyles.Add([Windows.Forms.RowStyle]::new($sizeType,$height))
    }
    return $panel
}
function Add-UiWide {
    param($Table, $Control, [int]$Row)
    $Table.Controls.Add($Control,0,$Row); $Table.SetColumnSpan($Control,3)
}
function Select-UiFolder {
    param($TextBox)
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Ordner auswählen'
    if (-not [string]::IsNullOrWhiteSpace($TextBox.Text) -and (Test-Path -LiteralPath $TextBox.Text -PathType Container)) {
        $dialog.SelectedPath = $TextBox.Text
    }
    try { if ($dialog.ShowDialog($form) -eq 'OK') { $TextBox.Text = $dialog.SelectedPath } } finally { $dialog.Dispose() }
}
function Show-UiError {
    param($ErrorValue)
    [void][Windows.Forms.MessageBox]::Show($form, $ErrorValue.ToString(), 'Aktion nicht ausgeführt', 'OK', 'Error')
}

$form = [Windows.Forms.Form]::new()
$sevenZipPath = Get-SetupSevenZipPath
$chocolateyPath = Get-SetupChocolateyPath
$form.Text = "Windows Setup Backup $script:SetupBackupVersion"
$form.ClientSize = [Drawing.Size]::new(1060,875)
$form.MinimumSize = [Drawing.Size]::new(960,800)
$form.StartPosition = 'CenterScreen'; $form.Font = [Drawing.Font]::new('Segoe UI',9.5)
$form.AutoScaleMode = 'Dpi'; $form.BackColor = [Drawing.Color]::FromArgb(246,248,251)
$root = [Windows.Forms.TableLayoutPanel]::new()
$root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 5; $root.Padding = [Windows.Forms.Padding]::new(12)
foreach ($height in @(45,-1,215,24,30)) {
    $style = if ($height -eq -1) { [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100) } else { [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,$height) }
    [void]$root.RowStyles.Add($style)
}
$form.Controls.Add($root)
$title = New-UiLabel "Windows Setup Backup $script:SetupBackupVersion  |  Programme und Einstellungen"
$title.Font = [Drawing.Font]::new('Segoe UI',15,[Drawing.FontStyle]::Bold)
$root.Controls.Add($title,0,0)
$tabs = [Windows.Forms.TabControl]::new(); $tabs.Dock = 'Fill'
$root.Controls.Add($tabs,0,1)
$backupTab = [Windows.Forms.TabPage]::new('Sicherung')
$restoreTab = [Windows.Forms.TabPage]::new('Wiederherstellung')
$extrasTab = [Windows.Forms.TabPage]::new('Zusatzbereiche')
$scheduleTab = [Windows.Forms.TabPage]::new('Zeitplan')
foreach ($tab in @($backupTab,$restoreTab,$extrasTab,$scheduleTab)) { $tab.AutoScroll = $true; $tab.BackColor = [Drawing.Color]::White; [void]$tabs.TabPages.Add($tab) }

# Backup tab
$backupTable = New-UiTable @(48,38,0,28,64,28,64,38,38,38,0,48)
$backupTab.Controls.Add($backupTable)
Add-UiWide $backupTable (New-UiLabel 'Sichert Programmlisten, Startmenü und Windows-Einstellungen. Persönliche Dateien kommen weiterhin über OneDrive.') 0
$destination = [Windows.Forms.TextBox]::new(); $destination.Dock = 'Fill'
$destination.Text = 'C:\Users\andre\OneDrive\Backup\Windows\GigabyteA16'
$backupTable.Controls.Add((New-UiLabel 'Sicherungsziel'),0,1); $backupTable.Controls.Add($destination,1,1)
$browseDestination = New-UiButton 'Ordner ...' 105; $backupTable.Controls.Add($browseDestination,2,1)
$backupFlags = New-UiFlow
$backupWinget = New-UiCheck 'WinGet-Programme' $true
$backupPython = New-UiCheck 'Python / pip' $true
$backupChocolatey = New-UiCheck 'Chocolatey-Pakete' ([bool]$chocolateyPath)
$backupChocolatey.Enabled = [bool]$chocolateyPath
$backupDeveloper = New-UiCheck 'Entwicklereinstellungen'
$backupAgreements = New-UiCheck 'WinGet-Quellenbedingungen akzeptieren'
foreach ($control in @($backupWinget,$backupChocolatey,$backupPython,$backupDeveloper,$backupAgreements)) { $backupFlags.Controls.Add($control) }
Add-UiWide $backupTable $backupFlags 2
Add-UiWide $backupTable (New-UiLabel 'Weitere Python-Interpreter (optional, ein vollständiger Pfad pro Zeile, z. B. Projekt\.venv\Scripts\python.exe):') 3
$extraPython = [Windows.Forms.TextBox]::new(); $extraPython.Multiline = $true; $extraPython.ScrollBars = 'Vertical'; $extraPython.Dock = 'Fill'
Add-UiWide $backupTable $extraPython 4
$customFoldersLabel = New-UiLabel 'Benutzerdefinierte Ordner (optional, ein vollständiger Pfad pro Zeile):'
Add-UiWide $backupTable $customFoldersLabel 5
$customFolders = [Windows.Forms.TextBox]::new(); $customFolders.Multiline = $true; $customFolders.ScrollBars = 'Vertical'; $customFolders.Dock = 'Fill'
$backupTable.Controls.Add($customFolders,0,6); $backupTable.SetColumnSpan($customFolders,2)
$browseCustomFolder = New-UiButton 'Hinzufügen ...' 105; $backupTable.Controls.Add($browseCustomFolder,2,6)
$excludedExtensions = [Windows.Forms.TextBox]::new(); $excludedExtensions.Dock = 'Fill'; $excludedExtensions.Text = 'tmp'
$backupTable.Controls.Add((New-UiLabel 'Dateiendungen ausschließen'),0,7); $backupTable.Controls.Add($excludedExtensions,1,7); $backupTable.SetColumnSpan($excludedExtensions,2)
$archiveOptions = New-UiFlow
$archiveText = if ($sevenZipPath) { 'Zusätzlich als Archiv packen (ZIP / 7z mit Passwort)' } else { 'Zusätzlich als ZIP packen' }
$createArchive = New-UiCheck $archiveText $true
$archiveOptions.Controls.Add($createArchive)
Add-UiWide $backupTable $archiveOptions 8
$archivePassword = [Windows.Forms.TextBox]::new(); $archivePassword.Dock = 'Fill'; $archivePassword.UseSystemPasswordChar = $true
$archivePasswordLabel = New-UiLabel 'Archivpasswort (optional)'
$backupTable.Controls.Add($archivePasswordLabel,0,9); $backupTable.Controls.Add($archivePassword,1,9); $backupTable.SetColumnSpan($archivePassword,2)
$archivePasswordLabel.Visible = [bool]$sevenZipPath; $archivePassword.Visible = [bool]$sevenZipPath
$backupButtons = New-UiFlow
$startBackup = New-UiButton 'Sicherung starten' 170
$savePreferences = New-UiButton 'Einstellungen speichern' 195
$openDestination = New-UiButton 'Zielordner öffnen' 165
foreach ($control in @($startBackup,$savePreferences,$openDestination)) { $backupButtons.Controls.Add($control) }
Add-UiWide $backupTable $backupButtons 10
$archiveHint = if ($sevenZipPath) { "7-Zip erkannt: $sevenZipPath. Mit Passwort wird ein AES-256-geschütztes 7z-Archiv erzeugt; ohne Passwort ein ZIP." } else { '7-Zip wurde nicht gefunden. Daher steht nur ein ZIP ohne Passwortschutz zur Verfügung.' }
$archiveHint += ' Das Windows-Feature-Inventar wird nur bei als Administrator gestarteter GUI erstellt.'
Add-UiWide $backupTable (New-UiLabel $archiveHint) 11

# Restore tab
$restoreTable = New-UiTable @(38,110,45,0,0,28,110,0,35,35,38)
$restoreTab.Controls.Add($restoreTable)
$restoreRoot = [Windows.Forms.TextBox]::new(); $restoreRoot.Dock = 'Fill'; $restoreRoot.Text = $destination.Text
$restoreTable.Controls.Add((New-UiLabel 'Backup-Ordner / Quelle'),0,0); $restoreTable.Controls.Add($restoreRoot,1,0)
$browseRestore = New-UiButton 'Auswählen ...' 105; $restoreTable.Controls.Add($browseRestore,2,0)
$grid = [Windows.Forms.DataGridView]::new()
$grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false; $grid.MultiSelect = $false; $grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [Drawing.Color]::White
foreach ($column in @(@('Date','Zeitpunkt'),@('Computer','Rechner'),@('Winget','WinGet'),@('Python','pip-Umgebungen'),@('Files','Dateien'),@('State','Status'))) { [void]$grid.Columns.Add($column[0],$column[1]) }
$grid.Columns['Date'].FillWeight = 150
Add-UiWide $restoreTable $grid 1
$backupDetails = New-UiLabel 'Quelle wählen oder Liste aktualisieren. Es werden der Ordner selbst und seine direkten Unterordner geprüft.'
$restoreTable.Controls.Add($backupDetails,0,2); $restoreTable.SetColumnSpan($backupDetails,2)
$browseRestoreZip = New-UiButton 'ZIP ...' 105; $restoreTable.Controls.Add($browseRestoreZip,2,2)
$restoreFlags = New-UiFlow
$restorePrograms = New-UiCheck 'WinGet-Programme'
$restoreSettings = New-UiCheck 'Einstellungen'
$restoreShortcuts = New-UiCheck 'Startmenü-Verknüpfungen'
$restoreCommon = New-UiCheck 'Auch gemeinsames Startmenü (Admin)'
$restorePip = New-UiCheck 'Python / pip'
$restoreVersions = New-UiCheck 'Gespeicherte WinGet-Versionen'
$restoreAgreements = New-UiCheck 'Paket-/Quellenbedingungen akzeptieren'
foreach ($control in @($restorePrograms,$restoreSettings,$restoreShortcuts,$restoreCommon,$restorePip,$restoreVersions,$restoreAgreements)) { $restoreFlags.Controls.Add($control) }
Add-UiWide $restoreTable $restoreFlags 3
$packageLabel = New-UiLabel 'WinGet-Pakete zur Wiederherstellung (alle sind zunächst ausgewählt):'
Add-UiWide $restoreTable $packageLabel 5
$packageList = [Windows.Forms.CheckedListBox]::new(); $packageList.Dock = 'Fill'; $packageList.CheckOnClick = $true
$packageList.HorizontalScrollbar = $true; $packageList.DisplayMember = 'Label'
Add-UiWide $restoreTable $packageList 6
$packageButtons = New-UiFlow
$selectAllPackages = New-UiButton 'Alle auswählen' 145
$selectNoPackages = New-UiButton 'Keine auswählen' 145
foreach ($control in @($selectAllPackages,$selectNoPackages)) { $packageButtons.Controls.Add($control) }
Add-UiWide $restoreTable $packageButtons 7
$extrasTable = New-UiTable @(45,0,28,85,28,100,28,100,0,38)
$extrasTab.Controls.Add($extrasTable)
$extrasSelection = New-UiLabel 'Zuerst im Reiter Wiederherstellung eine Sicherung auswählen.'
Add-UiWide $extrasTable $extrasSelection 0
$customRestoreLabel = New-UiLabel 'Benutzerdefinierte Ordner (Ziel ist der gespeicherte Originalpfad):'
Add-UiWide $extrasTable $customRestoreLabel 2
$customRestoreList = [Windows.Forms.CheckedListBox]::new(); $customRestoreList.Dock = 'Fill'; $customRestoreList.CheckOnClick = $true; $customRestoreList.DisplayMember = 'Label'
Add-UiWide $extrasTable $customRestoreList 3
$chocolateyRestoreLabel = New-UiLabel 'Chocolatey-Pakete (Abhängigkeitspakete sind standardmäßig abgewählt):'
Add-UiWide $extrasTable $chocolateyRestoreLabel 4
$chocolateyRestoreList = [Windows.Forms.CheckedListBox]::new(); $chocolateyRestoreList.Dock = 'Fill'; $chocolateyRestoreList.CheckOnClick = $true; $chocolateyRestoreList.DisplayMember = 'Label'
$chocolateyRestoreList.Enabled = $false
Add-UiWide $extrasTable $chocolateyRestoreList 5
$storeRestoreLabel = New-UiLabel 'Store-Apps (Registrierung vorhandener Windows-Payloads; WinGet-Pakete sind oben enthalten):'
Add-UiWide $extrasTable $storeRestoreLabel 6
$storeRestoreList = [Windows.Forms.CheckedListBox]::new(); $storeRestoreList.Dock = 'Fill'; $storeRestoreList.CheckOnClick = $true; $storeRestoreList.DisplayMember = 'Label'
Add-UiWide $extrasTable $storeRestoreList 7
$extraRestoreFlags = New-UiFlow
$restoreVSCode = New-UiCheck 'VS-Code-Erweiterungen'
$restoreModules = New-UiCheck 'PowerShell-Module'
$restoreChocolatey = New-UiCheck 'Chocolatey-Pakete'
$restoreUserEnvironment = New-UiCheck 'Benutzer-Umgebungsvariablen'
$restoreMachineEnvironment = New-UiCheck 'System-Umgebungsvariablen (Admin)'
$restoreWindowsComponents = New-UiCheck 'Windows-Features/Capabilities (Admin)'
$restoreConnections = New-UiCheck 'Netzwerkdrucker und Netzlaufwerke'
foreach ($control in @($restoreChocolatey,$restoreVSCode,$restoreModules,$restoreUserEnvironment,$restoreMachineEnvironment,$restoreWindowsComponents,$restoreConnections)) { $extraRestoreFlags.Controls.Add($control) }
Add-UiWide $extrasTable $extraRestoreFlags 8
$extrasButtons = New-UiFlow
$previewExtras = New-UiButton 'Vorschau (WhatIf)' 155
$startExtras = New-UiButton 'Zusatzbereiche wiederherstellen' 230
foreach ($control in @($previewExtras,$startExtras)) { $extrasButtons.Controls.Add($control) }
Add-UiWide $extrasTable $extrasButtons 1
Add-UiWide $extrasTable (New-UiLabel 'Systemvariablen und Windows-Komponenten benötigen beim tatsächlichen Wiederherstellen Administratorrechte.') 9
$pipEnvironment = [Windows.Forms.ComboBox]::new(); $pipEnvironment.DropDownStyle = 'DropDownList'; $pipEnvironment.Dock = 'Fill'; $pipEnvironment.DisplayMember = 'Label'
$restoreTable.Controls.Add((New-UiLabel 'pip-Umgebung'),0,8); $restoreTable.Controls.Add($pipEnvironment,1,8); $restoreTable.SetColumnSpan($pipEnvironment,2)
$targetPython = [Windows.Forms.TextBox]::new(); $targetPython.Dock = 'Fill'
$restoreTable.Controls.Add((New-UiLabel 'Ziel: python.exe'),0,9); $restoreTable.Controls.Add($targetPython,1,9)
$browsePython = New-UiButton 'Datei ...' 105; $restoreTable.Controls.Add($browsePython,2,9)
$restoreButtons = New-UiFlow
$refreshBackups = New-UiButton 'Liste aktualisieren' 155
$previewRestore = New-UiButton 'Vorschau (WhatIf)' 155
$startRestore = New-UiButton 'Wiederherstellen' 160
$deleteBackup = New-UiButton 'Sicherung löschen' 165
$deleteBackup.Enabled = $false
foreach ($control in @($refreshBackups,$previewRestore,$startRestore,$deleteBackup)) { $restoreButtons.Controls.Add($control) }
Add-UiWide $restoreTable $restoreButtons 4
Add-UiWide $restoreTable (New-UiLabel 'Reihenfolge: WinGet zuerst, danach Dateien und Einstellungen. Weitere Optionen befinden sich im Reiter Zusatzbereiche.') 10

# Scheduled task tab
$scheduleTable = New-UiTable @(55,36,36,36,38,64,0,98)
$scheduleTab.Controls.Add($scheduleTable)
Add-UiWide $scheduleTable (New-UiLabel 'Die Aufgabe übernimmt Ziel und Optionen aus dem Reiter Sicherung. Sie läuft im Hintergrund unter deinem Benutzer, wenn du angemeldet bist (auch bei gesperrtem Bildschirm).') 0
$frequency = [Windows.Forms.ComboBox]::new(); $frequency.DropDownStyle = 'DropDownList'; $frequency.Dock = 'Fill'; [void]$frequency.Items.AddRange(@('Täglich','Wöchentlich')); $frequency.SelectedIndex = 0
$scheduleTable.Controls.Add((New-UiLabel 'Wiederholung'),0,1); $scheduleTable.Controls.Add($frequency,1,1)
$weekDay = [Windows.Forms.ComboBox]::new(); $weekDay.DropDownStyle = 'DropDownList'; $weekDay.Dock = 'Fill'; [void]$weekDay.Items.AddRange(@('Montag','Dienstag','Mittwoch','Donnerstag','Freitag','Samstag','Sonntag')); $weekDay.SelectedIndex = 6; $weekDay.Enabled = $false
$scheduleTable.Controls.Add((New-UiLabel 'Wochentag'),0,2); $scheduleTable.Controls.Add($weekDay,1,2)
$scheduleTime = [Windows.Forms.DateTimePicker]::new(); $scheduleTime.Format = 'Custom'; $scheduleTime.CustomFormat = 'HH:mm'; $scheduleTime.ShowUpDown = $true; $scheduleTime.Value = [datetime]::Today.AddHours(19)
$scheduleTable.Controls.Add((New-UiLabel 'Uhrzeit (lokal)'),0,3); $scheduleTable.Controls.Add($scheduleTime,1,3)
$allowBattery = New-UiCheck 'Auch im Akkubetrieb sichern'
Add-UiWide $scheduleTable $allowBattery 4
$schedulePreview = New-UiLabel 'Noch keine Aufgabe angelegt. Die aktuellen Sicherungsoptionen werden beim Speichern übernommen.'
Add-UiWide $scheduleTable $schedulePreview 5
$scheduleButtons = New-UiFlow
$saveTask = New-UiButton 'Zeitplan speichern' 165
$refreshTask = New-UiButton 'Status aktualisieren' 165
$toggleTask = New-UiButton 'Deaktivieren' 135
$removeTask = New-UiButton 'Aufgabe entfernen' 165
foreach ($control in @($saveTask,$refreshTask,$toggleTask,$removeTask)) { $scheduleButtons.Controls.Add($control) }
Add-UiWide $scheduleTable $scheduleButtons 6
$taskStatus = New-UiLabel 'Status noch nicht geladen. Es wird keine Aufgabe automatisch angelegt.'
Add-UiWide $scheduleTable $taskStatus 7

# Common output area
$outputPanel = [Windows.Forms.TableLayoutPanel]::new(); $outputPanel.Dock = 'Fill'; $outputPanel.ColumnCount = 2; $outputPanel.RowCount = 2
[void]$outputPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
[void]$outputPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute,175))
[void]$outputPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,38))
[void]$outputPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
$outputPanel.Controls.Add((New-UiLabel 'Ausgabe der laufenden Aktion'),0,0)
$openLogs = New-UiButton 'Protokolle öffnen' 165; $outputPanel.Controls.Add($openLogs,1,0)
$output = [Windows.Forms.RichTextBox]::new(); $output.Dock = 'Fill'; $output.ReadOnly = $true; $output.WordWrap = $false
$output.Font = [Drawing.Font]::new('Consolas',9); $output.BackColor = [Drawing.Color]::FromArgb(25,32,44); $output.ForeColor = [Drawing.Color]::FromArgb(224,234,243)
$output.Text = 'Bereit. Sicherung, Wiederherstellung oder Zeitplan auswählen.'
$outputPanel.Controls.Add($output,0,1); $outputPanel.SetColumnSpan($output,2); $root.Controls.Add($outputPanel,0,2)
$progress = [Windows.Forms.ProgressBar]::new(); $progress.Dock = 'Fill'; $root.Controls.Add($progress,0,3)
$status = New-UiLabel 'Bereit'; $root.Controls.Add($status,0,4)

function Save-UiPreferences {
    Save-SetupDocument @{
        Destination = $destination.Text; RestoreRoot = $restoreRoot.Text
        Winget = $backupWinget.Checked; Chocolatey = $backupChocolatey.Checked; Python = $backupPython.Checked; Developer = $backupDeveloper.Checked
        Agreements = $backupAgreements.Checked; ExtraPython = $extraPython.Text
        CustomFolders = $customFolders.Text; ExcludedExtensions = $excludedExtensions.Text; CreateArchive = $createArchive.Checked
        Frequency = $frequency.SelectedIndex; Day = $weekDay.SelectedIndex; Time = $scheduleTime.Value.ToString('HH:mm'); Battery = $allowBattery.Checked
    } $settingsPath
}
function New-UiBackupRequest {
    $request = [pscustomobject]@{
        SchemaVersion = 1; Operation = 'Backup'; Destination = (Get-SetupAbsoluteDirectory $destination.Text)
        IncludeDeveloperSettings = $backupDeveloper.Checked; SkipWinget = -not $backupWinget.Checked
        SkipChocolatey = -not $backupChocolatey.Checked
        SkipPython = -not $backupPython.Checked; AcceptSourceAgreements = $backupAgreements.Checked
        PythonExecutables = @($extraPython.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        CustomFolders = @($customFolders.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        ExcludedExtensions = @($excludedExtensions.Text -split '[,;\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        CreateArchive = $createArchive.Checked; ProtectedArchivePassword = Protect-SetupSecret $archivePassword.Text
    }
    if ($request.SkipPython) { $request.PythonExecutables = @() }
    Test-SetupRequest $request
    return $request
}
function New-UiRestoreRequest {
    param([bool]$Preview, [bool]$ExtrasOnly = $false)
    if (-not $script:selectedBackup -or $script:selectedBackup.Error) { throw 'Eine gültige Sicherung in der Liste auswählen.' }
    $packageIds = @($packageList.CheckedItems | ForEach-Object { $_.Id })
    $customKeys = @($customRestoreList.CheckedItems | ForEach-Object { $_.Key })
    $storeFamilies = @($storeRestoreList.CheckedItems | ForEach-Object { $_.Family })
    $chocolateyPackages = @($chocolateyRestoreList.CheckedItems | ForEach-Object { $_.Id })
    if ($ExtrasOnly -and $restoreChocolatey.Checked -and $chocolateyPackages.Count -eq 0) { throw 'Mindestens ein Chocolatey-Paket auswählen oder die Option Chocolatey-Pakete deaktivieren.' }
    if (-not $ExtrasOnly -and $restorePrograms.Checked -and $packageIds.Count -eq 0) { throw 'Mindestens ein WinGet-Paket auswählen oder die Option WinGet-Programme deaktivieren.' }
    $request = [pscustomobject]@{
        SchemaVersion = 1; Operation = 'Restore'; BackupPath = $script:selectedBackup.Path; Preview = $Preview
        Programs = (-not $ExtrasOnly -and $restorePrograms.Checked); Settings = (-not $ExtrasOnly -and $restoreSettings.Checked); Shortcuts = (-not $ExtrasOnly -and $restoreShortcuts.Checked)
        IncludeCommonStartMenu = (-not $ExtrasOnly -and $restoreCommon.Checked); UseSavedVersions = $restoreVersions.Checked
        AcceptAgreements = $restoreAgreements.Checked; PythonPackages = (-not $ExtrasOnly -and $restorePip.Checked)
        PackageIds = $(if ($ExtrasOnly) { @() } else { $packageIds })
        CustomFolderKeys = $(if ($ExtrasOnly) { $customKeys } else { @() }); StorePackageFamilies = $(if ($ExtrasOnly) { $storeFamilies } else { @() })
        ChocolateyPackages = $(if ($ExtrasOnly -and $restoreChocolatey.Checked) { $chocolateyPackages } else { @() })
        VSCodeExtensions = ($ExtrasOnly -and $restoreVSCode.Checked); PowerShellModules = ($ExtrasOnly -and $restoreModules.Checked)
        UserEnvironment = ($ExtrasOnly -and $restoreUserEnvironment.Checked); MachineEnvironment = ($ExtrasOnly -and $restoreMachineEnvironment.Checked)
        WindowsComponents = ($ExtrasOnly -and $restoreWindowsComponents.Checked); Connections = ($ExtrasOnly -and $restoreConnections.Checked)
        EnvironmentId = $(if (-not $ExtrasOnly -and $pipEnvironment.SelectedItem) { $pipEnvironment.SelectedItem.Id } else { '' })
        PythonExecutable = $(if ($ExtrasOnly) { '' } else { $targetPython.Text.Trim() })
    }
    Test-SetupRequest $request
    return $request
}
function Update-UiBackupList {
    $entries = @(Get-SetupBackupEntries $restoreRoot.Text | Sort-Object Created -Descending)
    $grid.Rows.Clear(); $script:selectedBackup = $null; $pipEnvironment.Items.Clear(); $packageList.Items.Clear(); $customRestoreList.Items.Clear(); $chocolateyRestoreList.Items.Clear(); $storeRestoreList.Items.Clear(); $targetPython.Clear(); $deleteBackup.Enabled = $false
    $restoreChocolatey.Checked = $false; $restoreChocolatey.Enabled = $false; $chocolateyRestoreList.Enabled = $false
    $extrasSelection.Text = 'Zuerst im Reiter Wiederherstellung eine Sicherung auswählen.'
    foreach ($entry in $entries) {
        $date = if ($entry.Error) { '-' } else { $entry.Created.ToString('dd.MM.yyyy HH:mm:ss') }
        $state = if ($entry.Error) { 'Nicht lesbar' } elseif ($entry.Warnings.Count -gt 0) { "$($entry.Warnings.Count) Warnungen" } else { 'Erfasst' }
        if ($entry.IsArchive -and -not $entry.Error) { $state = "ZIP | $state" }
        $rowIndex = $grid.Rows.Add($date, $entry.Computer, $(if ($entry.Winget) { 'Ja' } else { 'Nein' }), $entry.Python.Count, $entry.Files, $state)
        $grid.Rows[$rowIndex].Tag = $entry
    }
    if ($grid.Rows.Count -gt 0) { $grid.ClearSelection(); $grid.Rows[0].Selected = $true; Update-UiSelection }
    else { $backupDetails.Text = 'Keine abgeschlossenen Sicherungen (manifest.json) gefunden. Einen Backup-Ordner oder dessen übergeordneten Ordner wählen.' }
}
function Update-UiSelection {
    $deleteBackup.Enabled = $false
    if ($grid.SelectedRows.Count -eq 0) { return }
    $script:selectedBackup = $grid.SelectedRows[0].Tag
    $pipEnvironment.Items.Clear(); $packageList.Items.Clear(); $customRestoreList.Items.Clear(); $chocolateyRestoreList.Items.Clear(); $storeRestoreList.Items.Clear(); $targetPython.Clear(); $extrasSelection.Text = 'Zuerst im Reiter Wiederherstellung eine Sicherung auswählen.'
    foreach ($control in @($restoreChocolatey,$restoreVSCode,$restoreModules,$restoreUserEnvironment,$restoreMachineEnvironment,$restoreWindowsComponents,$restoreConnections)) { $control.Checked = $false; $control.Enabled = $false }
    if (-not $script:selectedBackup) { return }
    if ($script:selectedBackup.Error) { $backupDetails.Text = $script:selectedBackup.Error; return }
    $deleteBackup.Enabled = -not $script:selectedBackup.IsArchive
    $sourceType = if ($script:selectedBackup.IsArchive) { 'ZIP-Backup; wird vor der Wiederherstellung neben dem Archiv entpackt.' } else { 'Backup-Ordner' }
    $backupDetails.Text = $script:selectedBackup.Path + "`r`n" + "$sourceType | $($script:selectedBackup.Files) Dateien; $($script:selectedBackup.Warnings.Count) Warnungen."
    $extrasSelection.Text = "Ausgewählte Sicherung: $($script:selectedBackup.Path)"
    if ($script:selectedBackup.Winget) {
        $wingetDocument = Read-SetupBackupDocument $script:selectedBackup.Path 'winget-packages.json'
        foreach ($package in @($wingetDocument.Sources | ForEach-Object { $_.Packages } | Sort-Object PackageIdentifier)) {
            $item = [pscustomobject]@{ Id = [string]$package.PackageIdentifier; Version = [string]$package.Version
                Label = "$($package.PackageIdentifier)  |  $($package.Version)" }
            [void]$packageList.Items.Add($item, $true)
        }
    }
    foreach ($folder in @($script:selectedBackup.Manifest.CustomFolders | Where-Object { $_ -and $_.Key })) {
        [void]$customRestoreList.Items.Add([pscustomobject]@{ Key = [string]$folder.Key; Label = "$($folder.Source)  |  $($folder.FileCount) Dateien" }, $true)
    }
    if (Test-SetupBackupDocument $script:selectedBackup.Path 'package-managers.json') {
        $managerData = Read-SetupBackupDocument $script:selectedBackup.Path 'package-managers.json'
        $chocoPackages = @($managerData.Chocolatey.Packages)
        $chocoIds = @($chocoPackages | ForEach-Object { [string]$_.Id })
        foreach ($package in $chocoPackages) {
            $baseName = $package.Id -replace '\.(install|portable)$',''
            $dependency = $package.Id -match '\.extension$' -or (($package.Id -match '\.(install|portable)$') -and $chocoIds -contains $baseName)
            $item = [pscustomobject]@{ Id = [string]$package.Id; Version = [string]$package.Version; Label = "$($package.Id)  |  $($package.Version)" }
            [void]$chocolateyRestoreList.Items.Add($item, -not $dependency)
        }
    }
    $restoreChocolatey.Enabled = $chocolateyRestoreList.Items.Count -gt 0
    $chocolateyRestoreList.Enabled = $restoreChocolatey.Checked
    if (Test-SetupBackupDocument $script:selectedBackup.Path 'store-apps.json') {
        $storeDocument = Read-SetupBackupDocument $script:selectedBackup.Path 'store-apps.json'
        $storeApps = @($storeDocument.GetEnumerator() | Where-Object {
            $_.PackageFamilyName -and -not [bool]$_.IsFramework -and -not [bool]$_.IsResourcePackage -and -not [bool]$_.NonRemovable
        } | Sort-Object PackageFamilyName -Unique)
        foreach ($app in $storeApps) {
            [void]$storeRestoreList.Items.Add([pscustomobject]@{ Family = [string]$app.PackageFamilyName; Label = "$($app.Name)  |  $($app.Version)" }, $false)
        }
    }
    $developerAvailable = Test-SetupBackupDocument $script:selectedBackup.Path 'developer-packages.json'
    $environmentAvailable = Test-SetupBackupDocument $script:selectedBackup.Path 'environment-variables.json'
    $componentsAvailable = $false; $connectionsAvailable = $false
    if (Test-SetupBackupDocument $script:selectedBackup.Path 'windows-components.json') { $componentData = Read-SetupBackupDocument $script:selectedBackup.Path 'windows-components.json'; $componentsAvailable = @($componentData.OptionalFeatures).Count + @($componentData.Capabilities).Count -gt 0 }
    if (Test-SetupBackupDocument $script:selectedBackup.Path 'devices-connections.json') { $connectionData = Read-SetupBackupDocument $script:selectedBackup.Path 'devices-connections.json'; $connectionsAvailable = @($connectionData.MappedDrives).Count + @($connectionData.Printers | Where-Object Network).Count -gt 0 }
    if ($developerAvailable) { $developerData = Read-SetupBackupDocument $script:selectedBackup.Path 'developer-packages.json' }
    $restoreVSCode.Enabled = $developerAvailable -and @($developerData.VSCodeProducts | ForEach-Object { $_.Extensions }).Count -gt 0
    $restoreModules.Enabled = $developerAvailable -and @($developerData.PowerShellModules).Count -gt 0
    $restoreUserEnvironment.Enabled = $environmentAvailable; $restoreMachineEnvironment.Enabled = $environmentAvailable
    $restoreWindowsComponents.Enabled = $componentsAvailable; $restoreConnections.Enabled = $connectionsAvailable
    foreach ($environment in $script:selectedBackup.Python) {
        [void]$pipEnvironment.Items.Add([pscustomobject]@{ Id = $environment.Id; Executable = $environment.Executable
            Label = "$($environment.Id) | $($environment.Version) | $($environment.PackageCount) Pakete | $($environment.Executable)" })
    }
    if ($pipEnvironment.Items.Count -gt 0) { $pipEnvironment.SelectedIndex = 0 }
}
function Start-UiOperation {
    param($Request)
    if ($script:operation) { throw 'Eine Aktion läuft bereits.' }
    Save-UiPreferences
    $run = Join-Path $stateRoot ('Runs\' + [guid]::NewGuid().ToString('N'))
    $requestFile = Join-Path $run 'request.json'
    Save-SetupDocument $Request $requestFile
    $arguments = (Get-SetupTaskArguments $workerPath $requestFile) + ' -RunDirectory "' + $run + '"'
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run 'native-output.log') -RedirectStandardError (Join-Path $run 'native-errors.log')
    $script:operation = @{ Process = $process; Directory = $run; Started = Get-Date; Request = $Request }
    $script:lastRun = $run; $script:lastLogLength = -1
    $tabs.Enabled = $false; $output.Text = "Aktion gestartet ...`r`nProtokoll: $run"
    $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30
    $status.ForeColor = [Drawing.Color]::FromArgb(35,85,150); $status.Text = 'Aktion läuft ...'
}
function Update-UiTaskStatus {
    $task = Get-ManagedSetupTask
    if (-not $task) { $taskStatus.Text = 'Keine geplante Sicherung eingerichtet.'; $toggleTask.Enabled = $false; $removeTask.Enabled = $false; return }
    $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop
    $taskStatus.Text = "Aufgabe: $($task.TaskName)`r`nStatus: $($task.State) | Nächster Lauf: $($info.NextRunTime)`r`nLetzter Lauf: $($info.LastRunTime) | Ergebnis: $($info.LastTaskResult) (0 = erfolgreich, 2 = Warnungen, 1 = Fehler)`r`nProtokolle: $stateRoot\Runs"
    $toggleTask.Enabled = $true; $removeTask.Enabled = $true
    $toggleTask.Text = if ($task.State -eq 'Disabled') { 'Aktivieren' } else { 'Deaktivieren' }
}
function Update-UiSchedulePreview {
    $customCount = @($customFolders.Lines | Where-Object { $_.Trim() }).Count
    $schedulePreview.Text = "Ziel: $($destination.Text)`r`nWinGet: $($backupWinget.Checked) | Chocolatey: $($backupChocolatey.Checked) | pip: $($backupPython.Checked) | Eigene Ordner: $customCount | Archiv: $($createArchive.Checked)`r`nGeänderte Optionen werden erst mit 'Zeitplan speichern' in die Aufgabe übernommen."
}

# User actions: external changes happen only through these buttons.
$browseDestination.Add_Click({ try { Select-UiFolder $destination; Update-UiSchedulePreview } catch { Show-UiError $_ } })
$browseCustomFolder.Add_Click({ try {
    $selection = [Windows.Forms.TextBox]::new()
    Select-UiFolder $selection
    if ($selection.Text) {
        $lines = @($customFolders.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($lines -notcontains $selection.Text) { $customFolders.Lines = @($lines + $selection.Text) }
    }
} catch { Show-UiError $_ } })
$createArchive.Add_CheckedChanged({ $archivePassword.Enabled = $createArchive.Checked; Update-UiSchedulePreview })
$restoreChocolatey.Add_CheckedChanged({ $chocolateyRestoreList.Enabled = $restoreChocolatey.Checked })
$selectAllPackages.Add_Click({ for ($index = 0; $index -lt $packageList.Items.Count; $index++) { $packageList.SetItemChecked($index, $true) } })
$selectNoPackages.Add_Click({ for ($index = 0; $index -lt $packageList.Items.Count; $index++) { $packageList.SetItemChecked($index, $false) } })
$savePreferences.Add_Click({ try { $null = New-UiBackupRequest; Save-UiPreferences; $status.Text = 'Einstellungen gespeichert.' } catch { Show-UiError $_ } })
$startBackup.Add_Click({ try { Start-UiOperation (New-UiBackupRequest) } catch { Show-UiError $_ } })
$openDestination.Add_Click({ try {
    if (-not (Test-Path -LiteralPath $destination.Text -PathType Container)) { throw 'Der Zielordner existiert noch nicht. Er wird beim Backup angelegt.' }
    Start-Process -FilePath explorer.exe -ArgumentList ('"' + (Get-SetupAbsoluteDirectory $destination.Text) + '"')
} catch { Show-UiError $_ } })
$browseRestore.Add_Click({ try { Select-UiFolder $restoreRoot; Update-UiBackupList } catch { Show-UiError $_ } })
$browseRestoreZip.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new(); $dialog.Filter = 'ZIP-Backups (*.zip)|*.zip'; $dialog.CheckFileExists = $true
    try { if ($dialog.ShowDialog($form) -eq 'OK') { $restoreRoot.Text = $dialog.FileName; Update-UiBackupList } } catch { Show-UiError $_ } finally { $dialog.Dispose() }
})
$refreshBackups.Add_Click({ try { Update-UiBackupList } catch { Show-UiError $_ } })
$deleteBackup.Add_Click({
    try {
        if ($script:operation) { throw 'Während einer laufenden Aktion kann keine Sicherung gelöscht werden.' }
        if (-not $script:selectedBackup -or $script:selectedBackup.Error) { throw 'Zuerst eine gültige Sicherung auswählen.' }
        $selectedPath = $script:selectedBackup.Path
        $sourceRoot = $restoreRoot.Text
        $question = "Diese Sicherung dauerhaft löschen?`r`n`r`n$selectedPath`r`n`r`nDer gesamte ausgewählte Backup-Ordner wird entfernt. Liegt er in OneDrive, wird die Löschung synchronisiert."
        if ([Windows.Forms.MessageBox]::Show($form,$question,'Sicherung löschen','YesNo','Warning','Button2') -ne 'Yes') { return }
        $tabs.Enabled = $false; $form.UseWaitCursor = $true
        $status.Text = 'Sicherung wird gelöscht ...'; $status.Refresh()
        Remove-SetupBackup -BackupPath $selectedPath -SourceRoot $sourceRoot -Confirm:$false
        $output.AppendText("`r`nSicherung gelöscht: $selectedPath")
        if ($sourceRoot.TrimEnd('\') -eq $selectedPath.TrimEnd('\')) { $restoreRoot.Text = Split-Path -Path $selectedPath -Parent }
        Update-UiBackupList
        $status.Text = 'Ausgewählte Sicherung gelöscht.'
    } catch { $status.Text = 'Sicherung konnte nicht gelöscht werden.'; Show-UiError $_ }
    finally { $form.UseWaitCursor = $false; $tabs.Enabled = $true }
})
$grid.Add_SelectionChanged({ try { Update-UiSelection } catch { $backupDetails.Text = $_.Exception.Message } })
$pipEnvironment.Add_SelectedIndexChanged({ if ($pipEnvironment.SelectedItem) { $targetPython.Text = $pipEnvironment.SelectedItem.Executable } })
$browsePython.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new(); $dialog.Filter = 'Python-Interpreter (python.exe)|python.exe|Programme (*.exe)|*.exe'; $dialog.CheckFileExists = $true
    try { if ($dialog.ShowDialog($form) -eq 'OK') { $targetPython.Text = $dialog.FileName } } finally { $dialog.Dispose() }
})
$previewRestore.Add_Click({ try { Start-UiOperation (New-UiRestoreRequest $true) } catch { Show-UiError $_ } })
$previewExtras.Add_Click({ try { Start-UiOperation (New-UiRestoreRequest $true $true) } catch { Show-UiError $_ } })
$startExtras.Add_Click({ try {
    $request = New-UiRestoreRequest $false $true
    $description = "Ausgewählte Zusatzbereiche wiederherstellen?`r`n`r`n$($request.BackupPath)`r`n`r`nEigene Ordner: $($request.CustomFolderKeys.Count) | Chocolatey: $($request.ChocolateyPackages.Count) | Store-Apps: $($request.StorePackageFamilies.Count)`r`nVS Code: $($request.VSCodeExtensions) | Module: $($request.PowerShellModules) | Umgebung: $($request.UserEnvironment)/$($request.MachineEnvironment) | Windows: $($request.WindowsComponents) | Verbindungen: $($request.Connections)"
    if ([Windows.Forms.MessageBox]::Show($form,$description,'Zusatzbereiche wiederherstellen','YesNo','Warning','Button2') -eq 'Yes') { Start-UiOperation $request }
} catch { Show-UiError $_ } })
$startRestore.Add_Click({ try {
    $request = New-UiRestoreRequest $false
    $packageCount = if ($request.Programs) { $request.PackageIds.Count } else { 0 }
    $description = "Ausgewählte Bestandteile aus dieser Sicherung wiederherstellen?`r`n`r`n$($request.BackupPath)`r`n`r`nWinGet: $($request.Programs) ($packageCount Pakete) | Eigene Ordner: $($request.CustomFolderKeys.Count) | Store: $($request.StorePackageFamilies.Count)`r`nEinstellungen: $($request.Settings) | Verknüpfungen: $($request.Shortcuts) | pip: $($request.PythonPackages)`r`n"
    if ($request.PythonPackages) { $description += "Python-Ziel: $($request.PythonExecutable)`r`n" }
    $description += "`r`nVorhandene Einstellungen und Paketversionen können ersetzt werden."
    if ([Windows.Forms.MessageBox]::Show($form,$description,'Wiederherstellung starten','YesNo','Warning','Button2') -eq 'Yes') { Start-UiOperation $request }
} catch { Show-UiError $_ } })
$frequency.Add_SelectedIndexChanged({ $weekDay.Enabled = $frequency.SelectedIndex -eq 1 })
$tabs.Add_SelectedIndexChanged({ Update-UiSchedulePreview })
$refreshTask.Add_Click({ try { Update-UiTaskStatus } catch { Show-UiError $_ } })
$saveTask.Add_Click({ try {
    $request = New-UiBackupRequest
    $requestFile = Join-Path $stateRoot ('Schedules\' + [guid]::NewGuid().ToString('N') + '.json')
    Save-SetupDocument $request $requestFile
    $days = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    Register-SetupBackupTask -WorkerPath $workerPath -RequestPath $requestFile -Frequency $(if ($frequency.SelectedIndex -eq 0) { 'Daily' } else { 'Weekly' }) -Time $scheduleTime.Value -Day $days[$weekDay.SelectedIndex] -AllowBattery:$allowBattery.Checked
    Save-UiPreferences; Update-UiTaskStatus
    $status.Text = 'Geplante Sicherung gespeichert. Sie verwendet die jetzt ausgewählten Optionen.'
} catch { Show-UiError $_ } })
$toggleTask.Add_Click({ try {
    $task = Get-ManagedSetupTask
    if ($task) {
        if ($task.State -eq 'Disabled') { Enable-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop | Out-Null }
    }
    Update-UiTaskStatus
} catch { Show-UiError $_ } })
$removeTask.Add_Click({ try {
    $task = Get-ManagedSetupTask
    if ($task -and [Windows.Forms.MessageBox]::Show($form,'Nur die geplante Aufgabe entfernen? Vorhandene Backups bleiben erhalten.','Zeitplan entfernen','YesNo','Question','Button2') -eq 'Yes') {
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
    }
    Update-UiTaskStatus
} catch { Show-UiError $_ } })
$openLogs.Add_Click({ try {
    $folder = if ($script:lastRun) { $script:lastRun } else { Join-Path $stateRoot 'Runs' }
    if (-not (Test-Path -LiteralPath $folder)) { throw 'Es gibt noch keine GUI- oder Zeitplan-Protokolle.' }
    Start-Process -FilePath explorer.exe -ArgumentList ('"' + $folder + '"')
} catch { Show-UiError $_ } })

$timer = [Windows.Forms.Timer]::new(); $timer.Interval = 600
$timer.Add_Tick({
    if (-not $script:operation) { return }
    try {
        $run = $script:operation.Directory
        $logPath = Join-Path $run 'operation.log'
        if (Test-Path -LiteralPath $logPath) {
            $length = (Get-Item -LiteralPath $logPath).Length
            if ($length -ne $script:lastLogLength) {
                $lines = @(Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 400 -ErrorAction Stop)
                $output.Text = $lines -join "`r`n"; $output.SelectionStart = $output.TextLength; $output.ScrollToCaret()
                $script:lastLogLength = $length
                $stepLines = @($lines | Select-String -Pattern '\[(\d+)/8\]')
                if ($stepLines.Count -gt 0) {
                    $step = [int]$stepLines[-1].Matches[0].Groups[1].Value
                    $progress.Style = 'Continuous'; $progress.Value = [Math]::Min(99,[int](($step - 1) / 8 * 100))
                }
            }
        }
        $elapsed = (Get-Date) - $script:operation.Started
        $status.Text = 'Aktion läuft seit {0:mm\:ss}. Details im Ausgabefenster.' -f $elapsed
        if ($script:operation.Process.HasExited) {
            $code = $script:operation.Process.ExitCode
            $script:operation.Process.Dispose(); $script:operation = $null
            $tabs.Enabled = $true; $progress.Style = 'Continuous'
            foreach ($nativeLog in @('native-output.log','native-errors.log')) {
                $path = Join-Path $run $nativeLog
                if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 0) { $output.AppendText("`r`n" + (Get-Content -LiteralPath $path -Raw)) }
            }
            $resultPath = Join-Path $run 'result.json'
            $result = if (Test-Path -LiteralPath $resultPath) { Read-SetupDocument $resultPath } else { [pscustomobject]@{ Status = 'Failed'; Error = "Prozess mit Exitcode $code beendet; kein Abschlussbericht. Siehe Ausgabe." } }
            $message = switch ($result.Status) {
                'Completed' { 'Aktion erfolgreich abgeschlossen.' }
                'CompletedWithWarnings' { "Sicherung mit $($result.WarningCount) Warnungen abgeschlossen. Bitte das Protokoll prüfen." }
                'PreviewCompleted' { 'Vorschau abgeschlossen. Es wurde nichts wiederhergestellt.' }
                default { "Aktion fehlgeschlagen: $($result.Error)" }
            }
            if ($result.BackupPath) { $message += "`r`nSicherung: $($result.BackupPath)" }
            if ($result.ArchivePath) { $message += "`r`nArchiv: $($result.ArchivePath)" }
            if ($result.BackupPath) {
                $restoreRoot.Text = Split-Path -Path $result.BackupPath -Parent
                try { Update-UiBackupList } catch { $backupDetails.Text = $_.Exception.Message }
            }
            $status.Text = $message.Replace("`r`n",' ')
            $status.ForeColor = if ($result.Status -eq 'Failed') { [Drawing.Color]::Firebrick } elseif ($result.Status -eq 'CompletedWithWarnings') { [Drawing.Color]::DarkOrange } else { [Drawing.Color]::ForestGreen }
            $progress.Value = if ($result.Status -eq 'Failed') { 0 } else { 100 }
            [void][Windows.Forms.MessageBox]::Show($form,$message,'Aktion beendet','OK',$(if ($result.Status -eq 'Failed') { 'Error' } elseif ($result.Status -eq 'CompletedWithWarnings') { 'Warning' } else { 'Information' }))
        }
    } catch { $status.Text = 'Anzeige konnte nicht aktualisiert werden: ' + $_.Exception.Message }
})

if (Test-Path -LiteralPath $settingsPath) {
    try {
        $saved = Read-SetupDocument $settingsPath
        if ($saved.Destination) { $destination.Text = $saved.Destination }
        if ($saved.RestoreRoot) { $restoreRoot.Text = $saved.RestoreRoot }
        $backupWinget.Checked = [bool]$saved.Winget; $backupPython.Checked = [bool]$saved.Python
        if ($null -ne $saved.Chocolatey -and $chocolateyPath) { $backupChocolatey.Checked = [bool]$saved.Chocolatey }
        $backupDeveloper.Checked = [bool]$saved.Developer; $backupAgreements.Checked = [bool]$saved.Agreements
        $extraPython.Text = $saved.ExtraPython
        if ($null -ne $saved.CustomFolders) { $customFolders.Text = $saved.CustomFolders }
        if ($null -ne $saved.ExcludedExtensions) { $excludedExtensions.Text = $saved.ExcludedExtensions }
        if ($null -ne $saved.CreateArchive) { $createArchive.Checked = [bool]$saved.CreateArchive }
        $frequency.SelectedIndex = [Math]::Max(0,[Math]::Min(1,[int]$saved.Frequency))
        $weekDay.SelectedIndex = [Math]::Max(0,[Math]::Min(6,[int]$saved.Day))
        if ($saved.Time) { $scheduleTime.Value = [datetime]::Today.Add([timespan]::Parse($saved.Time)) }
        $allowBattery.Checked = [bool]$saved.Battery
    } catch { $output.Text = 'Gespeicherte GUI-Einstellungen konnten nicht vollständig geladen werden: ' + $_.Exception.Message }
}
Update-UiSchedulePreview
$form.Add_Shown({
    $timer.Start()
    try { if (Test-Path -LiteralPath $restoreRoot.Text -PathType Container) { Update-UiBackupList } } catch { $backupDetails.Text = $_.Exception.Message }
    try { Update-UiTaskStatus } catch { $taskStatus.Text = $_.Exception.Message }
})
$form.Add_FormClosing({ param($sender,$eventArgs)
    if ($script:operation) { $eventArgs.Cancel = $true; $status.Text = 'Eine Aktion läuft noch. Bitte bis zum Abschluss warten.' }
    else { try { Save-UiPreferences } catch { $status.Text = 'Einstellungen konnten nicht gespeichert werden.' } }
})
if ($ValidateOnly) {
    if ($ValidationBackupRoot) { $restoreRoot.Text = $ValidationBackupRoot; Update-UiBackupList }
    [pscustomobject]@{ Tabs = $tabs.TabPages.Count; BackupButton = $startBackup.Text; RestoreButton = $startRestore.Text
        TaskButton = $saveTask.Text; DefaultDestination = $destination.Text; SevenZipPath = $sevenZipPath
        ArchiveText = $createArchive.Text; PasswordOptionAvailable = [bool]$sevenZipPath; DeleteButton = $deleteBackup.Text
        BackupChocolateyEnabled = $backupChocolatey.Enabled; BackupChocolateyChecked = $backupChocolatey.Checked
        PackageItems = $packageList.Items.Count; ChocolateyItems = $chocolateyRestoreList.Items.Count; ChocolateyChecked = $chocolateyRestoreList.CheckedItems.Count
        ChocolateyOptionEnabled = $restoreChocolatey.Enabled; ChocolateyOptionChecked = $restoreChocolatey.Checked; ChocolateyListEnabled = $chocolateyRestoreList.Enabled
        CustomFolderItems = $customRestoreList.Items.Count; StoreItems = $storeRestoreList.Items.Count; SelectedIsArchive = [bool]$script:selectedBackup.IsArchive }
    $timer.Dispose(); $form.Dispose()
    return
}
try { [void]$form.ShowDialog() } finally { $timer.Stop(); $timer.Dispose(); $form.Dispose() }

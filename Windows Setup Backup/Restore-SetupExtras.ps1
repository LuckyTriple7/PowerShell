#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [string[]]$CustomFolderKeys = @(),
    [switch]$VSCodeExtensions,
    [switch]$PowerShellModules,
    [switch]$UserEnvironment,
    [switch]$MachineEnvironment,
    [switch]$WindowsComponents,
    [switch]$Connections,
    [string[]]$StorePackageFamilies = @(),
    [string[]]$ChocolateyPackages = @(),
    [switch]$UseSavedVersions,
    [switch]$Fonts,
    [switch]$WlanProfiles,
    [switch]$SshKeys,
    [string]$UndoRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
$backup = (Resolve-Path -LiteralPath $BackupPath).ProviderPath
$manifest = $null
if (@($CustomFolderKeys).Count -gt 0) { $manifest = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw | ConvertFrom-Json }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$customUndo = if ($UndoRoot) { Join-Path $UndoRoot ('Custom-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) } else { Join-Path $backup ('BeforeRestore-Custom-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
if (($MachineEnvironment -or $WindowsComponents) -and -not $isAdmin -and -not $WhatIfPreference) {
    throw 'System-Umgebungsvariablen und Windows-Komponenten erfordern Administratorrechte.'
}

if (@($ChocolateyPackages | Where-Object { $_ }).Count -gt 0) {
    $managerPath = Join-Path $backup 'package-managers.json'
    if (-not (Test-Path -LiteralPath $managerPath)) { throw 'Diese Sicherung enthält kein Chocolatey-Inventar.' }
    $managerData = Get-Content -LiteralPath $managerPath -Raw | ConvertFrom-Json
    Assert-SetupDocumentSchema $managerData 'package-managers.json'
    $availablePackages = @($managerData.Chocolatey.Packages)
    $chocoPath = Get-SetupChocolateyPath
    if (-not $chocoPath -and -not $WhatIfPreference) { throw 'Chocolatey wurde nicht gefunden. Zuerst Chocolatey oder UniGetUI installieren.' }
    $wingetIds = @()
    $wingetPath = Join-Path $backup 'winget-packages.json'
    if (Test-Path -LiteralPath $wingetPath) {
        $wingetData = Get-Content -LiteralPath $wingetPath -Raw | ConvertFrom-Json
        $wingetIds = @($wingetData.Sources | ForEach-Object { $_.Packages } | ForEach-Object { [string]$_.PackageIdentifier })
    }
    foreach ($id in @($ChocolateyPackages | Where-Object { $_ } | Select-Object -Unique)) {
        $package = @($availablePackages | Where-Object Id -eq $id)
        if ($package.Count -ne 1 -or $id -notmatch '^[a-zA-Z0-9_.-]+$') { throw "Unbekanntes oder ungültiges Chocolatey-Paket: $id" }
        $baseName = $id -replace '\.(install|portable)$',''
        if (@($wingetIds | Where-Object { ($_ -split '\.') -contains $baseName }).Count -gt 0) {
            Write-Warning "Mögliche Überschneidung mit WinGet: Chocolatey-Paket $id"
        }
        $target = if ($UseSavedVersions) { "$id $($package[0].Version)" } else { $id }
        if ($PSCmdlet.ShouldProcess($target, 'Chocolatey-Paket installieren')) {
            $arguments = @('install',$id,'--yes','--no-progress','--limit-output')
            if ($UseSavedVersions) { $arguments += "--version=$($package[0].Version)" }
            & $chocoPath @arguments
            if ($LASTEXITCODE -ne 0) { Write-Warning "Chocolatey-Paket konnte nicht installiert werden: $id (Exitcode $LASTEXITCODE)" }
        }
    }
}

foreach ($key in @($CustomFolderKeys | Select-Object -Unique)) {
    $folder = @($manifest.CustomFolders | Where-Object Key -eq $key)
    if ($folder.Count -ne 1) { throw "Unbekannter benutzerdefinierter Ordner: $key" }
    $targetRoot = [IO.Path]::GetFullPath([string]$folder[0].Source)
    Assert-SetupNoReparsePoint $targetRoot
    Write-Host "Benutzerdefinierter Ordner: $targetRoot"
    foreach ($file in @($manifest.Files | Where-Object Key -eq $key)) {
        $stored = if ($file.Stored) { [string]$file.Stored } else { "$($folder[0].StoredRoot)\$($file.Relative)" }
        $source = Join-SetupSafePath $backup $stored
        $target = Join-SetupSafePath $targetRoot ([string]$file.Relative)
        Assert-SetupNoReparsePoint $target
        if (Test-Path -LiteralPath $target -PathType Container) { throw "Dateiziel ist bereits ein Verzeichnis: $target" }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Prüfsumme stimmt nicht: $source" }
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $file.SHA256) { continue }
        if ($PSCmdlet.ShouldProcess($target, 'Benutzerdefinierte Datei wiederherstellen')) {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $previous = Join-SetupSafePath $customUndo "$key\$($file.Relative)"
                New-Item -ItemType Directory -Path (Split-Path $previous -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $target -Destination $previous -Force
            }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Quelldatei wurde nach der Vorabprüfung verändert: $source" }
            Copy-Item -LiteralPath $source -Destination $target -Force
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Wiederhergestellte Datei hat eine falsche Prüfsumme: $target" }
        }
    }
}

if ($Fonts -or $WlanProfiles -or $SshKeys) {
    $personalPath = Join-Path $backup 'personal-settings.json'
    if (-not (Test-Path -LiteralPath $personalPath)) { throw 'Diese Sicherung enthält keine Schriftarten, WLAN-Profile oder SSH-Schlüssel.' }
    $personal = Get-Content -LiteralPath $personalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-SetupDocumentSchema $personal 'personal-settings.json'
    function Get-PersonalSource {
        param($Item, [string]$Folder)
        if ([string]$Item.File -notlike "Personal\$Folder\*") { throw "Ungültiger Eintrag in personal-settings.json: $($Item.File)" }
        $source = Join-SetupSafePath $backup ([string]$Item.File)
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $Item.SHA256) { throw "Prüfsumme stimmt nicht: $source" }
        return $source
    }
    function Copy-PersonalFile {
        param([string]$Source, [string]$Target, [string]$UndoName, [string]$Hash)
        Assert-SetupNoReparsePoint $Target
        if ((Test-Path -LiteralPath $Target -PathType Leaf) -and (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -eq $Hash) { return $false }
        if (-not $PSCmdlet.ShouldProcess($Target, 'Datei wiederherstellen (vorhandene Datei vorher sichern)')) { return $false }
        if (Test-Path -LiteralPath $Target -PathType Leaf) {
            $previous = Join-SetupSafePath $customUndo $UndoName
            New-Item -ItemType Directory -Path (Split-Path $previous -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $Target -Destination $previous -Force
        }
        New-Item -ItemType Directory -Path (Split-Path $Target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Target -Force
        return $true
    }
    if ($Fonts) {
        $fontRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        $fontKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        foreach ($font in @($personal.Fonts)) {
            $source = Get-PersonalSource $font 'Fonts'
            $target = Join-SetupSafePath $fontRoot ([IO.Path]::GetFileName($source))
            $null = Copy-PersonalFile $source $target "Fonts\$([IO.Path]::GetFileName($source))" $font.SHA256
            if ([string]$font.Name -notmatch '^[^\x00]+$') { throw "Ungültiger Schriftartname: $($font.Name)" }
            $current = (Get-ItemProperty -LiteralPath $fontKey -Name $font.Name -ErrorAction SilentlyContinue).($font.Name)
            if ($current -ne $target -and $PSCmdlet.ShouldProcess([string]$font.Name, 'Benutzerschriftart registrieren')) {
                if (-not (Test-Path -LiteralPath $fontKey)) { New-Item -Path $fontKey -Force | Out-Null }
                New-ItemProperty -LiteralPath $fontKey -Name $font.Name -Value $target -PropertyType String -Force | Out-Null
            }
        }
        if (@($personal.Fonts).Count -gt 0) { Write-Host 'Schriftarten stehen nach einer erneuten Anmeldung in allen Programmen zur Verfügung.' }
    }
    if ($WlanProfiles) {
        if (-not $personal.SensitiveIncluded) { Write-Warning 'Diese Sicherung enthält keine WLAN-Profile (nur in verschlüsselten 7z-Backups).' }
        foreach ($wlan in @($personal.WlanProfiles)) {
            $source = Get-PersonalSource $wlan 'Wlan'
            if ($PSCmdlet.ShouldProcess([string]$wlan.Name, 'WLAN-Profil für den aktuellen Benutzer hinzufügen')) {
                # Short path for netsh, see backup; the file contains the key in plain text and is removed right away.
                $shortCopy = Join-Path ([IO.Path]::GetTempPath()) ('wsbw' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.xml')
                try {
                    Copy-Item -LiteralPath $source -Destination $shortCopy -Force
                    $netshOutput = @(& netsh.exe wlan add profile filename="$shortCopy" user=current 2>&1)
                    if ($LASTEXITCODE -ne 0) { Write-Warning "WLAN-Profil konnte nicht hinzugefügt werden: $($wlan.Name): $(($netshOutput | Out-String).Trim())" }
                    else { Write-Host "WLAN-Profil hinzugefügt: $($wlan.Name)" }
                } finally { Remove-Item -LiteralPath $shortCopy -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    if ($SshKeys) {
        if (-not $personal.SensitiveIncluded) { Write-Warning 'Diese Sicherung enthält keine SSH-Schlüssel (nur in verschlüsselten 7z-Backups).' }
        $sshRoot = Join-Path $env:USERPROFILE '.ssh'
        foreach ($sshFile in @($personal.SshFiles)) {
            $source = Get-PersonalSource $sshFile 'Ssh'
            $name = [IO.Path]::GetFileName($source)
            if ($name -notmatch '^[^\\/:*?"<>|]+$') { throw "Ungültiger SSH-Dateiname: $name" }
            # The new file inherits the profile ACL (user, SYSTEM, Administrators), which OpenSSH accepts for private keys.
            if (Copy-PersonalFile $source (Join-SetupSafePath $sshRoot $name) "Ssh\$name" $sshFile.SHA256) { Write-Host "SSH-Datei wiederhergestellt: $name" }
        }
    }
}

$developerPath = Join-Path $backup 'developer-packages.json'
if (($VSCodeExtensions -or $PowerShellModules) -and -not (Test-Path -LiteralPath $developerPath)) { throw 'Diese Sicherung enthält kein Entwicklerpaket-Inventar.' }
if (Test-Path -LiteralPath $developerPath) {
    $developer = Get-Content -LiteralPath $developerPath -Raw | ConvertFrom-Json
    Assert-SetupDocumentSchema $developer 'developer-packages.json'
    if ($VSCodeExtensions) {
        foreach ($product in @($developer.VSCodeProducts | Where-Object Status -eq 'Exported')) {
            $cli = $null
            $isCodium = $product.Product -eq 'VSCodium'
            foreach ($name in $(if ($isCodium) { @('codium.cmd','codium.exe') } else { @('code.cmd','code.exe') })) {
                $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
                if ($command) { $cli = $command.Source; break }
            }
            if (-not $cli) {
                $paths = if ($isCodium) { @("$env:LOCALAPPDATA\Programs\VSCodium\bin\codium.cmd", "$env:ProgramFiles\VSCodium\bin\codium.cmd") }
                    else { @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd") }
                foreach ($path in $paths) { if (Test-Path -LiteralPath $path -PathType Leaf) { $cli = $path; break } }
            }
            if (-not $cli) { Write-Warning "$($product.Product) ist nicht installiert; Erweiterungen werden übersprungen."; continue }
            foreach ($extension in $product.Extensions) {
                if ($extension.Id -notmatch '^([a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]+$') { throw "Ungültige Erweiterungs-ID: $($extension.Id)" }
                $argument = if ($UseSavedVersions) { "$($extension.Id)@$($extension.Version)" } else { [string]$extension.Id }
                if ($PSCmdlet.ShouldProcess("$($product.Product): $argument", 'Erweiterung installieren')) {
                    & $cli --install-extension $argument --force
                    if ($LASTEXITCODE -ne 0) { Write-Warning "Erweiterung konnte nicht installiert werden: $argument" }
                }
            }
        }
    }
    if ($PowerShellModules) {
        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) { throw 'Install-Module ist nicht verfügbar.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        foreach ($module in @($developer.PowerShellModules)) {
            if ($module.Name -notmatch '^[a-zA-Z0-9_.-]+$' -or $module.Repository -ne 'PSGallery') { Write-Warning "Modul wird nicht automatisch installiert: $($module.Name)"; continue }
            $parameters = @{ Name = [string]$module.Name; Repository = 'PSGallery'; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true; ErrorAction = 'Stop' }
            if ($UseSavedVersions) { $parameters.RequiredVersion = [string]$module.Version }
            if ($PSCmdlet.ShouldProcess("$($module.Name) $($module.Version)", 'PowerShell-Modul installieren')) {
                try { Install-Module @parameters } catch { Write-Warning "PowerShell-Modul konnte nicht installiert werden: $($module.Name): $_" }
            }
        }
    }
}

$environmentPath = Join-Path $backup 'environment-variables.json'
if (($UserEnvironment -or $MachineEnvironment) -and -not (Test-Path -LiteralPath $environmentPath)) { throw 'Diese Sicherung enthält kein Umgebungsvariablen-Inventar.' }
if (Test-Path -LiteralPath $environmentPath) {
    $environment = Get-Content -LiteralPath $environmentPath -Raw | ConvertFrom-Json
    Assert-SetupDocumentSchema $environment 'environment-variables.json'
    foreach ($variable in @($environment.Variables | Where-Object { ($UserEnvironment -and $_.Scope -eq 'User') -or ($MachineEnvironment -and $_.Scope -eq 'Machine') })) {
        if ($variable.Sensitive -or $null -eq $variable.Value) { Write-Warning "Sensible Umgebungsvariable wurde nicht gesichert: $($variable.Name)"; continue }
        if ($variable.Name -notmatch '^[^=\x00]+$') { throw "Ungültiger Variablenname: $($variable.Name)" }
        $registryPath = if ($variable.Scope -eq 'User') { 'HKCU:\Environment' } else { 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
        $current = (Get-ItemProperty -LiteralPath $registryPath -Name $variable.Name -ErrorAction SilentlyContinue).($variable.Name)
        $value = [string]$variable.Value
        if ($variable.Name -ieq 'Path' -and $current) {
            $entries = [Collections.Generic.List[string]]::new()
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in @(([string]$current -split ';') + ($value -split ';'))) { if ($entry -and $seen.Add($entry)) { $entries.Add($entry) } }
            $value = $entries -join ';'
        } elseif ($null -ne $current) { continue }
        $kind = if ($variable.RegistryKind -eq 'ExpandString') { 'ExpandString' } else { 'String' }
        if ($PSCmdlet.ShouldProcess("$($variable.Scope):$($variable.Name)", 'Umgebungsvariable ergänzen')) {
            New-ItemProperty -LiteralPath $registryPath -Name $variable.Name -Value $value -PropertyType $kind -Force | Out-Null
        }
    }
}

$componentsPath = Join-Path $backup 'windows-components.json'
if ($WindowsComponents) {
    if (-not (Test-Path -LiteralPath $componentsPath)) { throw 'Diese Sicherung enthält kein Windows-Komponenten-Inventar.' }
    $components = Get-Content -LiteralPath $componentsPath -Raw | ConvertFrom-Json
    Assert-SetupDocumentSchema $components 'windows-components.json'
    foreach ($feature in @($components.OptionalFeatures)) {
        if ($feature.FeatureName -notmatch '^[a-zA-Z0-9_.~-]+$') { throw "Ungültiger Featurename: $($feature.FeatureName)" }
        if ($PSCmdlet.ShouldProcess($feature.FeatureName, 'Optionales Windows-Feature aktivieren')) {
            try { Enable-WindowsOptionalFeature -Online -FeatureName $feature.FeatureName -All -NoRestart -ErrorAction Stop | Out-Null } catch { Write-Warning "Feature konnte nicht aktiviert werden: $($feature.FeatureName): $_" }
        }
    }
    foreach ($capability in @($components.Capabilities)) {
        if ($capability.Name -notmatch '^[a-zA-Z0-9_.~=-]+$') { throw "Ungültiger Capability-Name: $($capability.Name)" }
        if ($PSCmdlet.ShouldProcess($capability.Name, 'Windows-Capability installieren')) {
            try { Add-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop | Out-Null } catch { Write-Warning "Capability konnte nicht installiert werden: $($capability.Name): $_" }
        }
    }
}

$connectionsPath = Join-Path $backup 'devices-connections.json'
if ($Connections) {
    if (-not (Test-Path -LiteralPath $connectionsPath)) { throw 'Diese Sicherung enthält kein Drucker-/Netzlaufwerk-Inventar.' }
    $connectionData = Get-Content -LiteralPath $connectionsPath -Raw | ConvertFrom-Json
    Assert-SetupDocumentSchema $connectionData 'devices-connections.json'
    foreach ($printer in @($connectionData.Printers | Where-Object { $_.Network -and $_.ConnectionName })) {
        if ($printer.ConnectionName -notmatch '^\\\\[^\\]+\\[^\\]+$') { Write-Warning "Ungültige Druckerverbindung: $($printer.ConnectionName)"; continue }
        if ($PSCmdlet.ShouldProcess($printer.ConnectionName, 'Netzwerkdrucker verbinden')) {
            try { Add-Printer -ConnectionName $printer.ConnectionName -ErrorAction Stop } catch { Write-Warning "Netzwerkdrucker konnte nicht verbunden werden: $($printer.ConnectionName): $_" }
        }
    }
    foreach ($drive in @($connectionData.MappedDrives)) {
        if ($drive.DriveLetter -notmatch '^[a-zA-Z]$' -or $drive.RemotePath -notmatch '^\\\\[^\\]+\\[^\\]+') { Write-Warning "Ungültiges Netzlaufwerk: $($drive.DriveLetter) $($drive.RemotePath)"; continue }
        $existing = Get-PSDrive -Name $drive.DriveLetter -ErrorAction SilentlyContinue
        if ($existing) { if ($existing.Root -ne $drive.RemotePath) { Write-Warning "Laufwerksbuchstabe $($drive.DriveLetter): ist bereits belegt." }; continue }
        if ($PSCmdlet.ShouldProcess("$($drive.DriveLetter): -> $($drive.RemotePath)", 'Persistentes Netzlaufwerk verbinden')) {
            try { New-PSDrive -Name $drive.DriveLetter -PSProvider FileSystem -Root $drive.RemotePath -Persist -Scope Global -ErrorAction Stop | Out-Null } catch { Write-Warning "Netzlaufwerk konnte nicht verbunden werden: $($drive.DriveLetter): $_" }
        }
    }
}

if (@($StorePackageFamilies).Count -gt 0) {
    $storePath = Join-Path $backup 'store-apps.json'
    $appDocument = Get-Content -LiteralPath $storePath -Raw | ConvertFrom-Json
    $apps = @($appDocument.GetEnumerator())
    $registerCommand = Get-Command Add-AppxPackage -ErrorAction SilentlyContinue
    foreach ($family in @($StorePackageFamilies | Select-Object -Unique)) {
        if (@($apps | Where-Object PackageFamilyName -eq $family).Count -eq 0) { throw "Unbekannte Store-App: $family" }
        if (Get-AppxPackage -PackageTypeFilter Main | Where-Object PackageFamilyName -eq $family) { Write-Host "Store-App bereits registriert: $family"; continue }
        if ($registerCommand -and $registerCommand.Parameters.ContainsKey('RegisterByFamilyName')) {
            if ($PSCmdlet.ShouldProcess($family, 'Vorhandenen Appx-Payload registrieren')) {
                try { Add-AppxPackage -RegisterByFamilyName -MainPackage $family -ErrorAction Stop } catch { Write-Warning "Store-App benötigt eine manuelle Installation: $family ($_)" }
            }
        } else { Write-Warning "Store-App benötigt eine manuelle Installation: ms-windows-store://pdp/?PFN=$family" }
    }
}

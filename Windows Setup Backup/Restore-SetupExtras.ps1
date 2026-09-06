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
    [switch]$UseSavedVersions
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
$backup = (Resolve-Path -LiteralPath $BackupPath).ProviderPath
$manifest = $null
if (@($CustomFolderKeys).Count -gt 0) { $manifest = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw | ConvertFrom-Json }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$customUndo = Join-Path $backup ('BeforeRestore-Custom-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
if (($MachineEnvironment -or $WindowsComponents) -and -not $isAdmin -and -not $WhatIfPreference) {
    throw 'System-Umgebungsvariablen und Windows-Komponenten erfordern Administratorrechte.'
}

if (@($ChocolateyPackages | Where-Object { $_ }).Count -gt 0) {
    $managerPath = Join-Path $backup 'package-managers.json'
    if (-not (Test-Path -LiteralPath $managerPath)) { throw 'Diese Sicherung enthält kein Chocolatey-Inventar.' }
    $managerData = Get-Content -LiteralPath $managerPath -Raw | ConvertFrom-Json
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
    Write-Host "Benutzerdefinierter Ordner: $targetRoot"
    foreach ($file in @($manifest.Files | Where-Object Key -eq $key)) {
        $stored = if ($file.Stored) { [string]$file.Stored } else { "$($folder[0].StoredRoot)\$($file.Relative)" }
        $source = Join-SetupSafePath $backup $stored
        $target = Join-SetupSafePath $targetRoot ([string]$file.Relative)
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Prüfsumme stimmt nicht: $source" }
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $file.SHA256) { continue }
        if ($PSCmdlet.ShouldProcess($target, 'Benutzerdefinierte Datei wiederherstellen')) {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $previous = Join-SetupSafePath $customUndo "$key\$($file.Relative)"
                New-Item -ItemType Directory -Path (Split-Path $previous -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $target -Destination $previous -Force
            }
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
}

$developerPath = Join-Path $backup 'developer-packages.json'
if (($VSCodeExtensions -or $PowerShellModules) -and -not (Test-Path -LiteralPath $developerPath)) { throw 'Diese Sicherung enthält kein Entwicklerpaket-Inventar.' }
if (Test-Path -LiteralPath $developerPath) {
    $developer = Get-Content -LiteralPath $developerPath -Raw | ConvertFrom-Json
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

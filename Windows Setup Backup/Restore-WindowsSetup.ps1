#requires -Version 5.1
<#
.SYNOPSIS
Stellt ausdrücklich ausgewählte Bestandteile einer WindowsSetup-Sicherung wieder her.
.EXAMPLE
.\Restore-WindowsSetup.ps1 -BackupPath '.\Backups\PC-20260905-120000-000' -Settings -Shortcuts -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [switch]$Programs,
    [switch]$Settings,
    [switch]$Shortcuts,
    [switch]$IncludeCommonStartMenu,
    [switch]$UseSavedVersions,
    [switch]$AcceptAgreements,
    [string[]]$PackageIds = @(),
    [string[]]$CustomFolderKeys = @(),
    [switch]$VSCodeExtensions,
    [switch]$PowerShellModules,
    [switch]$UserEnvironment,
    [switch]$MachineEnvironment,
    [switch]$WindowsComponents,
    [switch]$Connections,
    [string[]]$StorePackageFamilies = @(),
    [string[]]$ChocolateyPackages = @(),
    [switch]$Fonts,
    [switch]$WlanProfiles,
    [switch]$SshKeys,
    [string]$UndoRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
$extrasSelected = @($CustomFolderKeys | Where-Object { $_ }).Count -gt 0 -or $VSCodeExtensions -or $PowerShellModules -or $UserEnvironment -or $MachineEnvironment -or $WindowsComponents -or $Connections -or @($StorePackageFamilies | Where-Object { $_ }).Count -gt 0 -or @($ChocolateyPackages | Where-Object { $_ }).Count -gt 0 -or $Fonts -or $WlanProfiles -or $SshKeys
if (-not ($Programs -or $Settings -or $Shortcuts -or $extrasSelected)) { throw 'Mindestens einen Bestandteil auswählen. Für eine Vorschau -WhatIf verwenden.' }
if ($IncludeCommonStartMenu -and -not $Shortcuts) { throw '-IncludeCommonStartMenu erfordert -Shortcuts.' }
$backup = (Resolve-Path -LiteralPath $BackupPath).ProviderPath
$manifest = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
if ($IncludeCommonStartMenu -and -not $WhatIfPreference) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Gemeinsames Startmenü: PowerShell als Administrator mit demselben Benutzer öffnen.' }
}
if ($manifest.OriginalProfile -ne $env:USERPROFILE) { Write-Warning 'Anderer Profilpfad: absolute Pfade in Verknüpfungen und Konfigurationen gegebenenfalls anpassen.' }
$locations = Get-SetupLocations
$selected = @($manifest.Files | Where-Object {
    ($Settings -and $locations.Contains($_.Key) -and $_.Key -notlike 'StartMenu*') -or
    ($Shortcuts -and $_.Key -eq 'StartMenuUser') -or
    ($Shortcuts -and $IncludeCommonStartMenu -and $_.Key -eq 'StartMenuCommon')
})
# Validate all selected files before installing programs or overwriting settings.
foreach ($file in $selected) {
    if (-not $locations.Contains($file.Key)) { throw "Unbekannter Bereich: $($file.Key)" }
    if (-not (Test-SetupFileAllowed $file.Key $file.Relative $locations[$file.Key])) { throw "Ungültige Datei: $($file.Relative)" }
    $source = Join-SetupSafePath $backup "Files\$($file.Key)\$($file.Relative)"
    $target = Join-SetupSafePath $locations[$file.Key].Path $file.Relative
    Assert-SetupNoReparsePoint $target
    if (Test-Path -LiteralPath $target -PathType Container) { throw "Dateiziel ist bereits ein Verzeichnis: $target" }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Prüfsumme stimmt nicht: $source" }
}
$registry = @()
if ($Settings) {
    $registry = Get-Content -LiteralPath (Join-Path $backup 'settings-registry.json') -Raw | ConvertFrom-Json
    $registry = @($registry)
    foreach ($entry in $registry) {
        $allowed = @(Get-SetupRegistrySpec | Where-Object { $_.Path -eq $entry.Path -and $_.Names -contains $entry.Name })
        if ($allowed.Count -ne 1 -or $entry.Type -ne 'DWord') { throw 'Nicht erlaubter Registry-Eintrag in der Sicherung.' }
        $null = [int]$entry.Value
    }
}

if ($Programs) {
    if (-not $manifest.WingetReady) { throw 'Diese Sicherung enthält keinen erfolgreich abgeschlossenen WinGet-Export.' }
    $packagePath = Join-Path $backup 'winget-packages.json'
    $packageDocument = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
    $availablePackages = @($packageDocument.Sources | ForEach-Object { $_.Packages })
    $availableIds = @($availablePackages | ForEach-Object { [string]$_.PackageIdentifier })
    $requestedIds = @($PackageIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $selectedIds = if ($requestedIds.Count -gt 0) { $requestedIds } else { $availableIds }
    foreach ($id in $selectedIds) {
        if ($availableIds -notcontains $id) { throw "Ausgewähltes WinGet-Paket ist nicht in der Sicherung enthalten: $id" }
    }
    Write-Host "Ausgewählte WinGet-Pakete: $($selectedIds.Count) von $($availableIds.Count)"
    foreach ($package in $availablePackages | Where-Object { $selectedIds -contains $_.PackageIdentifier } | Sort-Object PackageIdentifier) {
        Write-Host "  $($package.PackageIdentifier) | $($package.Version)"
    }
    $temporaryImport = $null
    try {
        if ($PSCmdlet.ShouldProcess($packagePath, "$($selectedIds.Count) Programme mit WinGet installieren")) {
            $importPath = $packagePath
            if ($selectedIds.Count -lt $availableIds.Count) {
                foreach ($source in $packageDocument.Sources) {
                    $source.Packages = @($source.Packages | Where-Object { $selectedIds -contains $_.PackageIdentifier })
                }
                $temporaryImport = Join-Path ([IO.Path]::GetTempPath()) ('WindowsSetup-WinGet-' + [guid]::NewGuid().ToString('N') + '.json')
                Write-SetupJson -Value $packageDocument -Path $temporaryImport
                $importPath = $temporaryImport
            }
            $winget = (Get-Command winget.exe -ErrorAction Stop).Source
            $arguments = @('import','--import-file',$importPath,'--no-upgrade','--disable-interactivity')
            if (-not $UseSavedVersions) { $arguments += '--ignore-versions' }
            if ($AcceptAgreements) { $arguments += '--accept-source-agreements','--accept-package-agreements' }
            & $winget @arguments
            if ($LASTEXITCODE -ne 0) { throw "WinGet meldet Exitcode $LASTEXITCODE. Einige Programme können bereits installiert sein. Einstellungen wurden noch nicht zurückgespielt." }
        }
    } finally {
        if ($temporaryImport -and (Test-Path -LiteralPath $temporaryImport)) { Remove-Item -LiteralPath $temporaryImport -Force -ErrorAction SilentlyContinue }
    }
}

$undo = if ($UndoRoot) { Join-Path $UndoRoot ('Windows-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) } else { Join-Path $backup ('BeforeRestore-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
Write-Host "Dateien: $($selected.Count); Windows-Einstellungen: $($registry.Count)."
$registrySaved = $false
foreach ($file in $selected) {
    $source = Join-SetupSafePath $backup "Files\$($file.Key)\$($file.Relative)"
    $target = Join-SetupSafePath $locations[$file.Key].Path $file.Relative
    Assert-SetupNoReparsePoint $target
    if (Test-Path -LiteralPath $target -PathType Container) { throw "Dateiziel ist bereits ein Verzeichnis: $target" }
    if ((Test-Path -LiteralPath $target -PathType Leaf) -and
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $file.SHA256) { continue }
    if ($PSCmdlet.ShouldProcess($target, 'Datei wiederherstellen (vorhandene Datei vorher sichern)')) {
        if (Test-Path -LiteralPath $target) {
            $previous = Join-SetupSafePath $undo "Files\$($file.Key)\$($file.Relative)"
            New-Item -ItemType Directory -Path (Split-Path $previous -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $previous -Force
        }
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Quelldatei wurde nach der Vorabprüfung verändert: $source" }
        Copy-Item -LiteralPath $source -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Wiederhergestellte Datei hat eine falsche Prüfsumme: $target" }
        Write-Host "Datei wiederhergestellt: $target"
    }
}
foreach ($entry in $registry) {
    $current = Get-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
    if ($null -ne $current -and $current.($entry.Name) -eq [int]$entry.Value) { continue }
    if ($PSCmdlet.ShouldProcess("$($entry.Path)\$($entry.Name)", "DWORD auf $($entry.Value) setzen")) {
        if (-not $registrySaved) {
            New-Item -ItemType Directory -Path $undo -Force | Out-Null
            Write-SetupJson -Value @(Get-SetupRegistryValues) -Path (Join-Path $undo 'settings-registry-before.json')
            Write-SetupJson -Value $registry -Path (Join-Path $undo 'settings-registry-requested.json')
            $registrySaved = $true
        }
        if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value ([int]$entry.Value) -PropertyType DWord -Force | Out-Null
        Write-Host "Einstellung wiederhergestellt: $($entry.Name)"
    }
}
$extraParameters = @{ BackupPath = $backup; CustomFolderKeys = $CustomFolderKeys; VSCodeExtensions = $VSCodeExtensions
    PowerShellModules = $PowerShellModules; UserEnvironment = $UserEnvironment; MachineEnvironment = $MachineEnvironment
    WindowsComponents = $WindowsComponents; Connections = $Connections; StorePackageFamilies = $StorePackageFamilies
    ChocolateyPackages = $ChocolateyPackages; Fonts = $Fonts; WlanProfiles = $WlanProfiles; SshKeys = $SshKeys; UseSavedVersions = $UseSavedVersions; UndoRoot = $UndoRoot; WhatIf = $WhatIfPreference; Confirm = $false }
if ($extrasSelected) { & (Join-Path $PSScriptRoot 'Restore-SetupExtras.ps1') @extraParameters }
if ($Shortcuts -and -not $IncludeCommonStartMenu) { Write-Host 'Gemeinsame Startmenü-Verknüpfungen ausgelassen. Optional: -IncludeCommonStartMenu mit Administratorrechten.' }
if (Test-Path -LiteralPath $undo) { Write-Host "Vorherige Einstellungen/Dateien: $undo (manuelle Rücksicherung)" }
if ($WhatIfPreference) { Write-Host 'Vorschau abgeschlossen. Keine Wiederherstellung ausgeführt.' }
else { Write-Host 'Ausgewählte Bestandteile wiederhergestellt. Für Explorer-Einstellungen gegebenenfalls ab- und anmelden.' }
Write-Host 'Angeheftete Startmenü- und Taskleisten-Apps werden nicht automatisch wiederhergestellt.'

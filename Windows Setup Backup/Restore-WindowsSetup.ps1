#requires -Version 5.1
<#
.SYNOPSIS
Stellt ausdruecklich ausgewaehlte Bestandteile einer WindowsSetup-Sicherung wieder her.
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
    [switch]$AcceptAgreements
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
if (-not ($Programs -or $Settings -or $Shortcuts)) { throw 'Mindestens -Programs, -Settings oder -Shortcuts auswaehlen. Fuer eine Vorschau -WhatIf verwenden.' }
if ($IncludeCommonStartMenu -and -not $Shortcuts) { throw '-IncludeCommonStartMenu erfordert -Shortcuts.' }
$backup = (Resolve-Path -LiteralPath $BackupPath).ProviderPath
$manifest = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
if ($IncludeCommonStartMenu -and -not $WhatIfPreference) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Gemeinsames Startmenue: PowerShell als Administrator mit demselben Benutzer oeffnen.' }
}
if ($manifest.OriginalProfile -ne $env:USERPROFILE) { Write-Warning 'Anderer Profilpfad: absolute Pfade in Verknuepfungen und Konfigurationen gegebenenfalls anpassen.' }
$locations = Get-SetupLocations
$selected = @($manifest.Files | Where-Object {
    ($Settings -and $_.Key -notlike 'StartMenu*') -or
    ($Shortcuts -and $_.Key -eq 'StartMenuUser') -or
    ($Shortcuts -and $IncludeCommonStartMenu -and $_.Key -eq 'StartMenuCommon')
})
# Validate all selected files before installing programs or overwriting settings.
foreach ($file in $selected) {
    if (-not $locations.Contains($file.Key)) { throw "Unbekannter Bereich: $($file.Key)" }
    if (-not (Test-SetupFileAllowed $file.Key $file.Relative $locations[$file.Key])) { throw "Ungueltige Datei: $($file.Relative)" }
    $source = Join-SetupSafePath $backup "Files\$($file.Key)\$($file.Relative)"
    $null = Join-SetupSafePath $locations[$file.Key].Path $file.Relative
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Pruefsumme stimmt nicht: $source" }
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
    if (-not $manifest.WingetReady) { throw 'Diese Sicherung enthaelt keinen erfolgreich abgeschlossenen WinGet-Export.' }
    $packagePath = Join-Path $backup 'winget-packages.json'
    $null = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
    if ($PSCmdlet.ShouldProcess($packagePath, 'Programme mit WinGet installieren')) {
        $winget = (Get-Command winget.exe -ErrorAction Stop).Source
        $arguments = @('import','--import-file',$packagePath,'--no-upgrade','--disable-interactivity')
        if (-not $UseSavedVersions) { $arguments += '--ignore-versions' }
        if ($AcceptAgreements) { $arguments += '--accept-source-agreements','--accept-package-agreements' }
        & $winget @arguments
        if ($LASTEXITCODE -ne 0) { throw "WinGet meldet Exitcode $LASTEXITCODE. Einige Programme koennen bereits installiert sein. Einstellungen wurden noch nicht zurueckgespielt." }
    }
}

$undo = Join-Path $backup ('BeforeRestore-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
Write-Host "Dateien: $($selected.Count); Windows-Einstellungen: $($registry.Count)."
$registrySaved = $false
foreach ($file in $selected) {
    $source = Join-SetupSafePath $backup "Files\$($file.Key)\$($file.Relative)"
    $target = Join-SetupSafePath $locations[$file.Key].Path $file.Relative
    if ((Test-Path -LiteralPath $target -PathType Leaf) -and
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $file.SHA256) { continue }
    if ($PSCmdlet.ShouldProcess($target, 'Datei wiederherstellen (vorhandene Datei vorher sichern)')) {
        if (Test-Path -LiteralPath $target) {
            $previous = Join-SetupSafePath $undo "Files\$($file.Key)\$($file.Relative)"
            New-Item -ItemType Directory -Path (Split-Path $previous -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $previous -Force
        }
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
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
if ($Shortcuts -and -not $IncludeCommonStartMenu) { Write-Host 'Gemeinsame Startmenue-Verknuepfungen ausgelassen. Optional: -IncludeCommonStartMenu mit Administratorrechten.' }
if (Test-Path -LiteralPath $undo) { Write-Host "Vorherige Einstellungen/Dateien: $undo (manuelle Ruecksicherung)" }
if ($WhatIfPreference) { Write-Host 'Vorschau abgeschlossen. Keine Wiederherstellung ausgefuehrt.' }
else { Write-Host 'Ausgewaehlte Bestandteile wiederhergestellt. Fuer Explorer-Einstellungen gegebenenfalls ab- und anmelden.' }
Write-Host 'Angeheftete Startmenue- und Taskleisten-Apps werden nicht automatisch wiederhergestellt.'

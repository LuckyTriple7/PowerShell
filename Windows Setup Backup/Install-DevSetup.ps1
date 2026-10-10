#requires -Version 5.1
<#
.SYNOPSIS
Installiert die Entwicklungsumgebung auf einem frischen Windows: Git, GitHub CLI, Node.js, VS Code, 7-Zip und OpenCode.
.DESCRIPTION
Installiert nur Programme. Einstellungen kommen danach aus einer WindowsSetup-Sicherung; -OpenRestore öffnet dafür die GUI.
Bereits vorhandene Programme werden übersprungen, das Skript kann also beliebig oft laufen.
.EXAMPLE
powershell.exe -ExecutionPolicy Bypass -File .\Install-DevSetup.ps1 -WhatIf
.EXAMPLE
powershell.exe -ExecutionPolicy Bypass -File .\Install-DevSetup.ps1 -OpenRestore
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$WingetPackages = @('Git.Git','GitHub.cli','OpenJS.NodeJS','Microsoft.VisualStudioCode','7zip.7zip'),
    [string[]]$NpmPackages = @('opencode-ai'),
    [switch]$OpenRestore
)
$ErrorActionPreference = 'Stop'
$failed = New-Object System.Collections.Generic.List[string]
# powershell.exe -File passes "a,b" as one string instead of an array.
$WingetPackages = @($WingetPackages -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$NpmPackages = @($NpmPackages -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $wingetCommand) { throw 'WinGet fehlt. Im Microsoft Store "App-Installer" installieren oder aktualisieren und das Skript erneut starten.' }
$winget = $wingetCommand.Source

foreach ($id in $WingetPackages) {
    & $winget list --id $id --exact --source winget --accept-source-agreements --disable-interactivity | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "Bereits installiert: $id"; continue }
    if ($PSCmdlet.ShouldProcess($id, 'Mit WinGet installieren')) {
        Write-Host "Installiere $id ..."
        & $winget install --id $id --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) { $failed.Add("WinGet: $id (Exitcode $LASTEXITCODE)") }
    }
}

# Installers extend PATH only for new processes; reload it so npm and code are usable right away.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
foreach ($package in $NpmPackages) {
    if (-not $npm) {
        if ($WhatIfPreference) { Write-Host "WhatIf: npm install -g $package (nach der Node.js-Installation)" }
        else { $failed.Add("npm: $package (npm nicht gefunden, Node.js-Installation prüfen)") }
        continue
    }
    & $npm.Source ls -g $package --depth=0 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "Bereits installiert: $package (npm)"; continue }
    if ($PSCmdlet.ShouldProcess($package, 'Mit npm global installieren')) {
        Write-Host "Installiere $package (npm) ..."
        & $npm.Source install -g $package
        if ($LASTEXITCODE -ne 0) { $failed.Add("npm: $package (Exitcode $LASTEXITCODE)") }
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Warning 'Nicht installiert:'
    $failed | ForEach-Object { Write-Warning "  $_" }
}
Write-Host 'Danach von Hand, weil Anmeldungen bewusst nicht gesichert werden:'
Write-Host '  gh auth login            GitHub CLI und Git-Zugang'
Write-Host '  opencode auth login      nur für Anbieter ohne API-Schlüssel in opencode.jsonc'
Write-Host '  VS Code                  Einstellungssynchronisierung anmelden, in der Claude-Code-Erweiterung anmelden'

if ($OpenRestore -and $PSCmdlet.ShouldProcess('WindowsSetup-GUI', 'Zum Wiederherstellen der Einstellungen öffnen')) {
    Start-Process -FilePath (Join-Path $PSScriptRoot 'Start-GUI.cmd')
}
if ($failed.Count -gt 0) { exit 1 }

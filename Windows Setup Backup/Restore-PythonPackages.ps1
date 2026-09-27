#requires -Version 5.1
<#
.SYNOPSIS
Installiert die pip-Paketliste einer gesicherten Umgebung in einen expliziten Zielinterpreter.
.EXAMPLE
.\Restore-PythonPackages.ps1 -BackupPath '.\Backups\PC-Zeitstempel' -EnvironmentId python-01 -PythonExecutable 'C:\Python314\python.exe' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [Parameter(Mandatory)][ValidatePattern('^python-[0-9]+$')][string]$EnvironmentId,
    [Parameter(Mandatory)][string]$PythonExecutable
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $BackupPath).ProviderPath
$manifest = Get-Content -LiteralPath (Join-Path $root 'Python\environments.json') -Raw | ConvertFrom-Json
if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Python-Sicherungsversion.' }
$environments = @($manifest.Environments | Where-Object Id -eq $EnvironmentId)
if ($environments.Count -ne 1 -or $environments[0].Status -ne 'Exported') { throw 'Keine erfolgreich exportierte Umgebung mit dieser ID vorhanden.' }
$environment = $environments[0]
$requirementsPath = Join-Path $root "Python\$EnvironmentId\requirements.txt"
if ((Get-FileHash -LiteralPath $requirementsPath -Algorithm SHA256).Hash -ne $environment.SHA256) { throw 'Pruefsumme der requirements.txt stimmt nicht.' }
$python = (Resolve-Path -LiteralPath $PythonExecutable).ProviderPath
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'PythonExecutable muss auf eine vorhandene python.exe zeigen.' }
$targetVersion = (& $python --version) -join ''
if ($LASTEXITCODE -ne 0) { throw 'Python-Version konnte nicht gelesen werden.' }
$savedMinor = [regex]::Match($environment.Version, 'Python (\d+\.\d+)').Groups[1].Value
$targetMinor = [regex]::Match($targetVersion, 'Python (\d+\.\d+)').Groups[1].Value
if (-not $savedMinor -or $savedMinor -ne $targetMinor) {
    throw "Python-Version passt nicht: gesichert $($environment.Version), Ziel $targetVersion. Passenden Interpreter verwenden."
}
Write-Host "Quelle: $EnvironmentId / $($environment.Version) / $($environment.PackageCount) Pakete"
Write-Host "Ziel: $python"
if ($PSCmdlet.ShouldProcess($python, "pip-Pakete aus $requirementsPath installieren")) {
    Write-Host 'Paketinstallation laeuft; Downloads koennen einige Minuten dauern.' -ForegroundColor Cyan
    & $python -m pip --disable-pip-version-check --no-input install --requirement $requirementsPath
    if ($LASTEXITCODE -ne 0) { throw "pip meldet Exitcode $LASTEXITCODE. Einige Pakete koennen bereits installiert sein; kein automatisches Rollback." }
    Write-Host 'PYTHON-PAKETE WIEDERHERGESTELLT' -ForegroundColor Green
} else {
    Write-Host 'Keine Paketinstallation ausgefuehrt.'
}

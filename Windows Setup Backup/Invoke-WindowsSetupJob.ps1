#requires -Version 5.1
<#
.SYNOPSIS
Fuehrt einen JSON-Auftrag fuer die GUI oder die Aufgabenplanung aus.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath, [string]$RunDirectory)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'WindowsSetup.GuiSupport.ps1')
if (-not $RunDirectory) { $RunDirectory = Join-Path $PSScriptRoot ('GuiState\Runs\' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
$log = Join-Path $RunDirectory 'operation.log'
$resultPath = Join-Path $RunDirectory 'result.json'
$result = [ordered]@{ Status = 'Running'; Started = (Get-Date).ToString('o'); Finished = $null; BackupPath = $null; WarningCount = 0; Error = $null }
$mutex = $null
$locked = $false
$exitCode = 1
function Write-JobLine {
    param($Value)
    if ($null -ne $Value) { Add-Content -LiteralPath $log -Value $Value.ToString() -Encoding UTF8 }
}
try {
    Write-JobLine ('Start: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $request = Read-SetupDocument $RequestPath
    Test-SetupRequest $request
    $mutexName = 'Local\WindowsSetupBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Eine andere Sicherung oder Wiederherstellung dieses Benutzers laeuft bereits.' }
    if ($request.Operation -eq 'Backup') {
        $parameters = @{
            Destination = [string]$request.Destination
            IncludeDeveloperSettings = [bool]$request.IncludeDeveloperSettings
            SkipWinget = [bool]$request.SkipWinget; SkipPython = [bool]$request.SkipPython
            AcceptSourceAgreements = [bool]$request.AcceptSourceAgreements
            PythonExecutables = [string[]]@($request.PythonExecutables)
        }
        & (Join-Path $PSScriptRoot 'Backup-WindowsSetup.ps1') @parameters *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }
            if ($_.PSObject.Properties['BackupPath']) {
                $result.BackupPath = $_.BackupPath
                $result.WarningCount = $_.WarningCount
            } else { Write-JobLine $_ }
        }
    } else {
        if ($request.Programs -or $request.Settings -or $request.Shortcuts) {
            $parameters = @{ BackupPath = [string]$request.BackupPath; Programs = [bool]$request.Programs
                Settings = [bool]$request.Settings; Shortcuts = [bool]$request.Shortcuts
                IncludeCommonStartMenu = [bool]$request.IncludeCommonStartMenu
                UseSavedVersions = [bool]$request.UseSavedVersions; AcceptAgreements = [bool]$request.AcceptAgreements
                WhatIf = [bool]$request.Preview; Confirm = $false }
            Write-JobLine 'Windows-Programme und Einstellungen werden verarbeitet ...'
            & (Join-Path $PSScriptRoot 'Restore-WindowsSetup.ps1') @parameters *>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }
                Write-JobLine $_
            }
        }
        if ($request.PythonPackages) {
            $parameters = @{ BackupPath = [string]$request.BackupPath; EnvironmentId = [string]$request.EnvironmentId
                PythonExecutable = [string]$request.PythonExecutable; WhatIf = [bool]$request.Preview; Confirm = $false }
            Write-JobLine 'Python-/pip-Umgebung wird verarbeitet ...'
            & (Join-Path $PSScriptRoot 'Restore-PythonPackages.ps1') @parameters *>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }
                Write-JobLine $_
            }
        }
    }
    $result.Status = if ($result.WarningCount -gt 0) { 'CompletedWithWarnings' } elseif ($request.Preview) { 'PreviewCompleted' } else { 'Completed' }
    $exitCode = if ($result.WarningCount -gt 0) { 2 } else { 0 }
    Write-JobLine "ABGESCHLOSSEN: $($result.Status)"
} catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
    Write-JobLine "FEHLER: $($result.Error)"
} finally {
    $result.Finished = (Get-Date).ToString('o')
    Save-SetupDocument $result $resultPath
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit $exitCode

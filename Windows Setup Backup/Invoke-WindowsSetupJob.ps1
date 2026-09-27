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
$result = [ordered]@{ Status = 'Running'; Started = (Get-Date).ToString('o'); Finished = $null; BackupPath = $null; ArchivePath = $null; WarningCount = 0; Error = $null }
$mutex = $null
$locked = $false
$exitCode = 1
$expandedBackup = $null
$restoreTempRoot = $null
$restoreTempCreated = $false
$restoreWarnings = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
function Write-JobLine {
    param($Value)
    if ($null -ne $Value) { Add-Content -LiteralPath $log -Value $Value.ToString() -Encoding UTF8 }
}
function Write-RestoreOutput {
    param($Value)
    if ($Value -is [System.Management.Automation.ErrorRecord]) { throw $Value }
    if ($Value -is [System.Management.Automation.WarningRecord]) {
        [void]$restoreWarnings.Add($Value.Message)
        Write-JobLine "WARNUNG: $($Value.Message)"
        return
    }
    Write-JobLine $Value
}
try {
    Write-JobLine ('Start: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $request = Read-SetupDocument $RequestPath
    Test-SetupRequest $request
    $mutexName = 'Local\WindowsSetupBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Eine andere Sicherung oder Wiederherstellung dieses Benutzers laeuft bereits.' }
    if ($request.Operation -eq 'Restore' -and [IO.Path]::GetExtension([string]$request.BackupPath) -in @('.zip','.7z')) {
        $archivePath = Get-SetupAbsoluteDirectory ([string]$request.BackupPath)
        $archiveType = [IO.Path]::GetExtension($archivePath).TrimStart('.').ToUpperInvariant()
        $archivePassword = Unprotect-SetupSecret ([string]$request.ProtectedArchivePassword)
        $restoreTempRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsSetupRestore-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $restoreTempRoot -ErrorAction Stop | Out-Null
        $restoreTempCreated = $true
        $privateArchive = Join-Path $restoreTempRoot ([IO.Path]::GetFileName($archivePath))
        Copy-Item -LiteralPath $archivePath -Destination $privateArchive -ErrorAction Stop
        $expandedBackup = Join-Path $restoreTempRoot 'ExpandedBackup'
        Write-JobLine "$archiveType-Backup wird in einem lokalen Temp-Ordner entpackt: $expandedBackup"
        $request.BackupPath = if ($archiveType -eq '7Z') { Expand-SetupSevenZipBackup $privateArchive $expandedBackup $archivePassword } else { Expand-SetupZipBackup $privateArchive $expandedBackup }
    }
    if ($request.Operation -eq 'Backup') {
        $skipChocolatey = if ($request.PSObject.Properties['SkipChocolatey']) { [bool]$request.SkipChocolatey } else { $true }
        $parameters = @{
            Destination = [string]$request.Destination
            IncludeDeveloperSettings = [bool]$request.IncludeDeveloperSettings
            SkipWinget = [bool]$request.SkipWinget; SkipPython = [bool]$request.SkipPython
            SkipChocolatey = $skipChocolatey
            AcceptSourceAgreements = [bool]$request.AcceptSourceAgreements
            PythonExecutables = [string[]]@($request.PythonExecutables)
            CustomFolders = [string[]]@($request.CustomFolders | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            ExcludedExtensions = [string[]]@($request.ExcludedExtensions | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            CreateArchive = [bool]$request.CreateArchive
            ArchivePassword = Unprotect-SetupSecret ([string]$request.ProtectedArchivePassword)
        }
        & (Join-Path $PSScriptRoot 'Backup-WindowsSetup.ps1') @parameters *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }
            if ($_.PSObject.Properties['BackupPath']) {
                $result.BackupPath = $_.BackupPath
                $result.ArchivePath = $_.ArchivePath
                $result.WarningCount = $_.WarningCount
            } else { Write-JobLine $_ }
        }
    } else {
        $requestCustomFolders = [string[]]@($request.CustomFolderKeys | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $requestStoreApps = [string[]]@($request.StorePackageFamilies | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $requestChocolatey = [string[]]@($request.ChocolateyPackages | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $hasWindowsRestore = $request.Programs -or $request.Settings -or $request.Shortcuts -or $requestCustomFolders.Count -gt 0 -or
            $request.VSCodeExtensions -or $request.PowerShellModules -or $request.UserEnvironment -or $request.MachineEnvironment -or
            $request.WindowsComponents -or $request.Connections -or $requestStoreApps.Count -gt 0 -or $requestChocolatey.Count -gt 0
        $windowsParameters = $null; $pythonParameters = $null
        if ($hasWindowsRestore) {
            $windowsParameters = @{ BackupPath = [string]$request.BackupPath; Programs = [bool]$request.Programs
                Settings = [bool]$request.Settings; Shortcuts = [bool]$request.Shortcuts
                IncludeCommonStartMenu = [bool]$request.IncludeCommonStartMenu
                UseSavedVersions = [bool]$request.UseSavedVersions; AcceptAgreements = [bool]$request.AcceptAgreements
                PackageIds = [string[]]@($request.PackageIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                CustomFolderKeys = $requestCustomFolders
                VSCodeExtensions = [bool]$request.VSCodeExtensions; PowerShellModules = [bool]$request.PowerShellModules
                UserEnvironment = [bool]$request.UserEnvironment; MachineEnvironment = [bool]$request.MachineEnvironment
                WindowsComponents = [bool]$request.WindowsComponents; Connections = [bool]$request.Connections
                StorePackageFamilies = $requestStoreApps
                ChocolateyPackages = $requestChocolatey; UndoRoot = (Join-Path $RunDirectory 'BeforeRestore')
                Confirm = $false }
        }
        if ($request.PythonPackages) {
            $pythonParameters = @{ BackupPath = [string]$request.BackupPath; EnvironmentId = [string]$request.EnvironmentId
                PythonExecutable = [string]$request.PythonExecutable; Confirm = $false }
        }
        if (-not [bool]$request.Preview) {
            if ($windowsParameters) {
                Write-JobLine 'Vollständige Vorabprüfung der Windows-Wiederherstellung ...'
                & (Join-Path $PSScriptRoot 'Restore-WindowsSetup.ps1') @windowsParameters -WhatIf *>&1 | ForEach-Object { Write-RestoreOutput $_ }
            }
            if ($pythonParameters) {
                Write-JobLine 'Vollständige Vorabprüfung der Python-Wiederherstellung ...'
                & (Join-Path $PSScriptRoot 'Restore-PythonPackages.ps1') @pythonParameters -WhatIf *>&1 | ForEach-Object { Write-RestoreOutput $_ }
            }
        }
        if ($windowsParameters) {
            Write-JobLine 'Windows-Programme und Einstellungen werden verarbeitet ...'
            & (Join-Path $PSScriptRoot 'Restore-WindowsSetup.ps1') @windowsParameters -WhatIf:([bool]$request.Preview) *>&1 | ForEach-Object { Write-RestoreOutput $_ }
        }
        if ($pythonParameters) {
            Write-JobLine 'Python-/pip-Umgebung wird verarbeitet ...'
            & (Join-Path $PSScriptRoot 'Restore-PythonPackages.ps1') @pythonParameters -WhatIf:([bool]$request.Preview) *>&1 | ForEach-Object { Write-RestoreOutput $_ }
        }
    }
    if ($restoreTempCreated -and (Test-Path -LiteralPath $restoreTempRoot)) {
        Remove-Item -LiteralPath $restoreTempRoot -Recurse -Force -ErrorAction Stop
        $restoreTempCreated = $false; $restoreTempRoot = $null; $expandedBackup = $null
    }
    if ($request.Operation -eq 'Restore') { $result.WarningCount = $restoreWarnings.Count }
    $result.Status = if ($request.Preview -and $result.WarningCount -gt 0) { 'PreviewCompletedWithWarnings' } elseif ($result.WarningCount -gt 0) { 'CompletedWithWarnings' } elseif ($request.Preview) { 'PreviewCompleted' } else { 'Completed' }
    $exitCode = if ($result.WarningCount -gt 0) { 2 } else { 0 }
    Write-JobLine "ABGESCHLOSSEN: $($result.Status)"
} catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
    Write-JobLine "FEHLER: $($result.Error)"
} finally {
    if ($restoreTempCreated -and $restoreTempRoot -and (Test-Path -LiteralPath $restoreTempRoot)) {
        Remove-Item -LiteralPath $restoreTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $restoreTempRoot) {
            $result.Status = 'Failed'; $result.Error = "Temporäre entschlüsselte Restore-Daten konnten nicht entfernt werden: $restoreTempRoot"; $exitCode = 1
        }
    }
    $result.Finished = (Get-Date).ToString('o')
    Save-SetupDocument $result $resultPath
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit $exitCode

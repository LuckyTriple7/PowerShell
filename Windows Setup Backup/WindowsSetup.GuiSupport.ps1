#requires -Version 5.1
# Data and validation shared by the GUI and its background worker.
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
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '["\r\n]') { throw 'Bitte einen gueltigen absoluten Ordnerpfad angeben.' }
    if ($Path -notmatch '^([a-zA-Z]:[\\/]|\\\\[^\\]+\\[^\\]+)') { throw 'Ein absoluter Pfad ist erforderlich, zum Beispiel C:\Backups.' }
    [IO.Path]::GetFullPath($Path.Trim())
}

function Get-SetupBackupEntries {
    param([string]$Root)
    $directory = Get-SetupAbsoluteDirectory $Root
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Ordner nicht gefunden: $directory" }
    $folders = @($directory)
    $folders += @(Get-ChildItem -LiteralPath $directory -Directory -ErrorAction Stop | Select-Object -ExpandProperty FullName)
    foreach ($folder in $folders) {
        $manifestPath = Join-Path $folder 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        try {
            $manifest = Read-SetupDocument $manifestPath
            if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
            $python = @()
            $pythonPath = Join-Path $folder 'Python\environments.json'
            if (Test-Path -LiteralPath $pythonPath) {
                $pythonDocument = Read-SetupDocument $pythonPath
                if ($pythonDocument.SchemaVersion -ne 1) { throw 'Unbekannte Python-Sicherungsversion.' }
                $python = @($pythonDocument.Environments | Where-Object Status -eq 'Exported')
            }
            [pscustomobject]@{
                Path = $folder; Created = ([datetime]$manifest.Created).ToLocalTime(); Computer = $manifest.Computer
                Winget = [bool]$manifest.WingetReady; Python = $python; Files = @($manifest.Files).Count
                Warnings = @($manifest.Warnings); Manifest = $manifest; Error = $null
            }
        } catch {
            [pscustomobject]@{ Path = $folder; Created = [datetime]::MinValue; Computer = '?'; Winget = $false
                Python = @(); Files = 0; Warnings = @(); Manifest = $null; Error = $_.Exception.Message }
        }
    }
}

function Remove-SetupBackup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$BackupPath, [Parameter(Mandatory)][string]$SourceRoot)
    $ErrorActionPreference = 'Stop'
    $source = (Get-SetupAbsoluteDirectory $SourceRoot).TrimEnd('\')
    $target = (Get-SetupAbsoluteDirectory $BackupPath).TrimEnd('\')
    # Only the selected backup itself or a direct child of the displayed source.
    if ($target -ne $source -and (Split-Path -Path $target -Parent).TrimEnd('\') -ne $source) {
        throw 'Der ausgewaehlte Ordner liegt ausserhalb der angezeigten Backup-Quelle.'
    }
    $item = Get-Item -LiteralPath $target -Force
    if (-not $item.PSIsContainer -or $item.LinkType) { throw 'Das Loeschziel muss ein echter Backup-Ordner sein.' }
    $manifest = Read-SetupDocument (Join-Path $target 'manifest.json')
    if ($manifest.SchemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($manifest.Computer)) { throw 'Kein gueltiges Backup-Verzeichnis.' }
    $expectedName = '^' + [regex]::Escape($manifest.Computer) + '-\d{8}-\d{6}-\d{3}$'
    if ($item.Name -notmatch $expectedName) { throw 'Der Ordnername entspricht keinem erzeugten Backup. Er wird nicht automatisch geloescht.' }
    $mutex = [Threading.Mutex]::new($false, ('Local\WindowsSetupBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Eine Sicherung oder Wiederherstellung laeuft bereits. Bitte spaeter loeschen.' }
        if ($PSCmdlet.ShouldProcess($target, 'Ausgewaehlten Backup-Ordner dauerhaft loeschen')) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
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
    if ($Request.Operation -eq 'Backup') {
        $null = Get-SetupAbsoluteDirectory $Request.Destination
        foreach ($python in @($Request.PythonExecutables)) {
            if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "Zusaetzlicher Python-Interpreter fehlt: $python" }
        }
    } else {
        $root = Get-SetupAbsoluteDirectory $Request.BackupPath
        $manifest = Read-SetupDocument (Join-Path $root 'manifest.json')
        if ($manifest.SchemaVersion -ne 1) { throw 'Unbekannte Sicherungsversion.' }
        if (-not ($Request.Programs -or $Request.Settings -or $Request.Shortcuts -or $Request.PythonPackages)) { throw 'Mindestens einen Bestandteil zur Wiederherstellung auswaehlen.' }
        if ($Request.Programs -and -not $manifest.WingetReady) { throw 'Dieser Sicherung fehlt eine verwendbare WinGet-Liste.' }
        if ($Request.IncludeCommonStartMenu -and -not $Request.Shortcuts) { throw 'Gemeinsames Startmenue erfordert Startmenue-Verknuepfungen.' }
        if ($Request.IncludeCommonStartMenu -and -not $Request.Preview) {
            $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'Fuer das gemeinsame Startmenue die GUI als Administrator mit demselben Benutzerkonto starten oder diese Option abwaehlen.'
            }
        }
        if ($Request.PythonPackages) {
            if ($Request.EnvironmentId -notmatch '^python-[0-9]+$') { throw 'Eine gesicherte pip-Umgebung auswaehlen.' }
            if (-not (Test-Path -LiteralPath $Request.PythonExecutable -PathType Leaf)) { throw 'Vorhandene python.exe als Wiederherstellungsziel auswaehlen.' }
            $python = Read-SetupDocument (Join-Path $root 'Python\environments.json')
            $matches = @($python.Environments | Where-Object { $_.Id -eq $Request.EnvironmentId -and $_.Status -eq 'Exported' })
            if ($python.SchemaVersion -ne 1 -or $matches.Count -ne 1) { throw 'Die ausgewaehlte pip-Umgebung ist nicht wiederherstellbar.' }
        }
    }
}

function Get-SetupTaskName {
    'WindowsSetupBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-SetupTaskArguments {
    param([string]$WorkerPath, [string]$RequestPath)
    foreach ($path in @($WorkerPath, $RequestPath)) {
        if ($path -match '["\r\n]') { throw 'Ungueltiger Pfad fuer die Aufgabenplanung.' }
    }
    '-NoProfile -NonInteractive -WindowStyle Hidden -File "{0}" -RequestPath "{1}"' -f $WorkerPath, $RequestPath
}

function Get-ManagedSetupTask {
    $task = Get-ScheduledTask -TaskName (Get-SetupTaskName) -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task -and $task.Description -notlike 'Windows Setup Backup GUI;*') {
        throw 'Unter diesem Namen existiert eine fremde Aufgabe. Sie wird nicht geaendert.'
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
    if ($request.Operation -ne 'Backup') { throw 'Geplant werden ausschliesslich Sicherungen.' }
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

#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BackupPath, [switch]$IncludeDeveloperSettings, [switch]$SkipChocolatey)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')
$warnings = [Collections.Generic.List[string]]::new()

function Add-ExtraWarning {
    param([string]$Message)
    $warnings.Add($Message)
    Write-Warning $Message
}

function Get-PersistentEnvironment {
    param([string]$Scope, [string]$RegistryPath)
    $key = Get-Item -LiteralPath $RegistryPath -ErrorAction Stop
    foreach ($name in $key.GetValueNames()) {
        $sensitive = $name -match '(?i)(password|passwd|token|secret|credential|api.?key|private.?key|connection.?string|(^|[_-])(auth|pat|sas|key)([_-]|$))'
        [pscustomobject]@{
            Scope = $Scope; Name = $name; Sensitive = $sensitive
            Value = if ($sensitive) { $null } else { $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            RegistryKind = $key.GetValueKind($name).ToString()
        }
    }
}

$environment = @()
try { $environment += @(Get-PersistentEnvironment User 'HKCU:\Environment') } catch { Add-ExtraWarning "Benutzer-Umgebungsvariablen konnten nicht gelesen werden: $_" }
try { $environment += @(Get-PersistentEnvironment Machine 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment') } catch { Add-ExtraWarning "System-Umgebungsvariablen konnten nicht gelesen werden: $_" }
Write-SetupJson @{ SchemaVersion = 1; Variables = @($environment) } (Join-Path $BackupPath 'environment-variables.json')

$features = @(); $capabilities = @(); $componentsError = $null
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $features = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object State -eq 'Enabled' | Select-Object FeatureName, State)
        $capabilities = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object State -eq 'Installed' | Select-Object Name, State)
    } catch { $componentsError = $_.Exception.Message; Add-ExtraWarning "Windows-Komponenten konnten nicht vollständig inventarisiert werden: $_" }
} else {
    $componentsError = 'Windows-Features und Capabilities wurden übersprungen: Für dieses Teilinventar sind Administratorrechte erforderlich.'
    Write-Host $componentsError
}
Write-SetupJson @{ SchemaVersion = 1; OptionalFeatures = $features; Capabilities = $capabilities; Error = $componentsError } (Join-Path $BackupPath 'windows-components.json')

$printers = @(); $drives = @()
try {
    $cimPrinters = @(Get-CimInstance Win32_Printer -ErrorAction Stop)
    $printers = @($cimPrinters | ForEach-Object {
        $connection = if ($_.Network -and $_.ServerName -and $_.ShareName) { '\\' + $_.ServerName.TrimStart('\') + '\' + $_.ShareName } else { $null }
        [pscustomobject]@{ Name = $_.Name; Network = [bool]$_.Network; Default = [bool]$_.Default; ConnectionName = $connection
            DriverName = $_.DriverName; PortName = $_.PortName; Location = $_.Location; Comment = $_.Comment }
    })
} catch { Add-ExtraWarning "Drucker konnten nicht inventarisiert werden: $_" }
try {
    if (Test-Path 'HKCU:\Network') {
        $drives = @(Get-ChildItem 'HKCU:\Network' | ForEach-Object {
            $values = Get-ItemProperty -LiteralPath $_.PSPath
            [pscustomobject]@{ DriveLetter = $_.PSChildName; RemotePath = $values.RemotePath; UserName = $values.UserName; ProviderName = $values.ProviderName }
        })
    }
} catch { Add-ExtraWarning "Netzlaufwerke konnten nicht inventarisiert werden: $_" }
Write-SetupJson @{ SchemaVersion = 1; Printers = $printers; MappedDrives = $drives } (Join-Path $BackupPath 'devices-connections.json')

$developer = [ordered]@{ SchemaVersion = 1; VSCodeProducts = @(); PowerShellModules = @(); Warnings = @() }
if ($IncludeDeveloperSettings) {
    foreach ($product in @(
        @{ Name = 'VSCode'; Commands = @('code.cmd','code.exe'); Paths = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd") },
        @{ Name = 'VSCodium'; Commands = @('codium.cmd','codium.exe'); Paths = @("$env:LOCALAPPDATA\Programs\VSCodium\bin\codium.cmd", "$env:ProgramFiles\VSCodium\bin\codium.cmd") }
    )) {
        $cli = $null
        foreach ($name in $product.Commands) { $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue; if ($command) { $cli = $command.Source; break } }
        if (-not $cli) { foreach ($path in $product.Paths) { if (Test-Path -LiteralPath $path -PathType Leaf) { $cli = $path; break } } }
        $extensions = @(); $status = 'CliNotFound'
        if ($cli) {
            try {
                $lines = @(& $cli --list-extensions --show-versions 2>&1)
                if ($LASTEXITCODE -ne 0) { throw "Exitcode $LASTEXITCODE" }
                $extensions = @($lines | Where-Object { $_ -match '^([a-zA-Z0-9-]+\.)+[a-zA-Z0-9-]+@[^\s]+$' } | ForEach-Object {
                    $separator = $_.LastIndexOf('@'); [pscustomobject]@{ Id = $_.Substring(0,$separator); Version = $_.Substring($separator + 1) }
                })
                $status = 'Exported'
            } catch { $status = 'Failed'; Add-ExtraWarning "$($product.Name)-Erweiterungen konnten nicht erfasst werden: $_" }
        }
        $developer.VSCodeProducts += [pscustomobject]@{ Product = $product.Name; Status = $status; CliPath = $cli; Extensions = $extensions }
    }
    try {
        if (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue) {
            $developer.PowerShellModules = @(Get-InstalledModule -ErrorAction Stop | Where-Object { $_.Name -notin @('PowerShellGet','PackageManagement') } |
                Select-Object Name, Version, Repository | Sort-Object Name, Version)
        }
    } catch { Add-ExtraWarning "PowerShell-Module konnten nicht erfasst werden: $_" }
}
$developer.Warnings = @($warnings)
Write-SetupJson $developer (Join-Path $BackupPath 'developer-packages.json')

$chocolatey = [ordered]@{ Status = 'NotFound'; Executable = $null; Version = $null; Packages = @(); Error = $null }
$chocoPath = if ($SkipChocolatey) { $null } else { Get-SetupChocolateyPath }
if ($SkipChocolatey) { $chocolatey.Status = 'Skipped' }
if ($chocoPath) {
    $chocolatey.Executable = $chocoPath
    try {
        $versionLines = @(& $chocoPath --version 2>&1)
        $versionExit = $LASTEXITCODE
        if ($versionExit -ne 0) { throw "Versionsabfrage meldet Exitcode $versionExit" }
        $chocolatey.Version = [string]($versionLines | Select-Object -First 1)
        $majorVersion = 0; [void][int]::TryParse(($chocolatey.Version -split '\.')[0], [ref]$majorVersion)
        $arguments = if ($majorVersion -ge 2) { @('list','--limit-output') } else { @('list','--local-only','--limit-output') }
        $lines = @(& $chocoPath @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Exitcode $LASTEXITCODE" }
        $chocolatey.Packages = @($lines | Where-Object { $_ -match '^[^|\s]+\|[^|\s]+$' } | ForEach-Object {
            $parts = $_ -split '\|', 2; [pscustomobject]@{ Id = $parts[0]; Version = $parts[1] }
        } | Sort-Object Id)
        $chocolatey.Status = 'Exported'
    } catch { $chocolatey.Status = 'Failed'; $chocolatey.Error = $_.Exception.Message; Add-ExtraWarning "Chocolatey-Pakete konnten nicht erfasst werden: $_" }
}
Write-SetupJson @{ SchemaVersion = 1; Chocolatey = $chocolatey } (Join-Path $BackupPath 'package-managers.json')

[pscustomobject]@{ WarningCount = $warnings.Count; Warnings = @($warnings); EnvironmentCount = $environment.Count
    FeatureCount = $features.Count + $capabilities.Count; PrinterCount = $printers.Count; DriveCount = $drives.Count
    ExtensionCount = @($developer.VSCodeProducts | ForEach-Object { $_.Extensions }).Count; ModuleCount = @($developer.PowerShellModules).Count
    ChocolateyCount = @($chocolatey.Packages).Count }

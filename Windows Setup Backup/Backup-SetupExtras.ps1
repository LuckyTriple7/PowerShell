#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BackupPath, [switch]$IncludeDeveloperSettings, [switch]$SkipChocolatey, [switch]$IncludeSensitiveData, [switch]$IncludeClaude)
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

function Add-PersonalFile {
    param([string]$Source, [string]$Stored)
    $target = Join-SetupSafePath $BackupPath $Stored
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $target -Force
    (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
}
$personal = [ordered]@{ SchemaVersion = 1; SensitiveIncluded = [bool]$IncludeSensitiveData; Fonts = @(); WlanProfiles = @(); SshFiles = @(); ClaudeFiles = @(); References = @() }
# Per-user fonts only; fonts in C:\Windows\Fonts come with Windows or their installers.
try {
    $fontRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fontKey = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue
    if ($fontKey) {
        foreach ($name in $fontKey.GetValueNames()) {
            $path = [string]$fontKey.GetValue($name)
            if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $fontRoot $path }
            $leaf = [IO.Path]::GetFileName($path)
            if (-not $leaf -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or $leaf -notmatch '^[^\\/:*?"<>|]+$') { continue }
            if (-not ([IO.Path]::GetFullPath($path)).StartsWith($fontRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $stored = "Personal\Fonts\$leaf"
            $personal.Fonts += [pscustomobject]@{ Name = $name; File = $stored; SHA256 = (Add-PersonalFile $path $stored) }
        }
    }
} catch { Add-ExtraWarning "Benutzerschriftarten konnten nicht gesichert werden: $_" }
if ($IncludeSensitiveData) {
    $wlanTemp = Join-Path ([IO.Path]::GetTempPath()) ('wsbw' + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        # netsh truncates long folder paths and then writes elsewhere, so export into a short private folder first.
        New-Item -ItemType Directory -Path $wlanTemp -ErrorAction Stop | Out-Null
        $netshOutput = @(& netsh.exe wlan export profile key=clear folder="$wlanTemp" 2>&1)
        $exported = @(Get-ChildItem -LiteralPath $wlanTemp -Filter '*.xml' -File)
        if ($LASTEXITCODE -ne 0 -and $exported.Count -eq 0) { Write-Host "WLAN-Profile nicht exportiert (kein WLAN-Dienst?): $(($netshOutput | Out-String).Trim())" }
        $index = 0
        foreach ($file in $exported) {
            $index++
            $profileName = try { ([xml](Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8)).WLANProfile.name } catch { $file.BaseName }
            $stored = 'Personal\Wlan\wlan-{0:D3}.xml' -f $index
            $personal.WlanProfiles += [pscustomobject]@{ Name = [string]$profileName; File = $stored; SHA256 = (Add-PersonalFile $file.FullName $stored) }
        }
    } catch { Add-ExtraWarning "WLAN-Profile konnten nicht gesichert werden: $_" }
    finally { if (Test-Path -LiteralPath $wlanTemp) { Remove-Item -LiteralPath $wlanTemp -Recurse -Force -ErrorAction SilentlyContinue } }
    try {
        $sshRoot = Join-Path $env:USERPROFILE '.ssh'
        if (Test-Path -LiteralPath $sshRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $sshRoot -File -Force -ErrorAction Stop)) {
                if ($file.LinkType) { Add-ExtraWarning "Verknüpfte SSH-Datei wurde ausgelassen: $($file.FullName)"; continue }
                $stored = "Personal\Ssh\$($file.Name)"
                $personal.SshFiles += [pscustomobject]@{ File = $stored; SHA256 = (Add-PersonalFile $file.FullName $stored) }
            }
        }
    } catch { Add-ExtraWarning "SSH-Schlüssel konnten nicht gesichert werden: $_" }
}
if ($IncludeClaude) {
    try {
        $claudeRoot = Join-Path $env:USERPROFILE '.claude'
        if (Test-Path -LiteralPath $claudeRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $claudeRoot -File -Recurse -Force -ErrorAction Stop)) {
                $relative = $file.FullName.Substring($claudeRoot.Length + 1)
                if (-not (Test-SetupClaudePath $relative)) { continue }
                if ($file.LinkType) { Add-ExtraWarning "Verknüpfte Claude-Datei wurde ausgelassen: $($file.FullName)"; continue }
                $stored = "Personal\Claude\$relative"
                try { $personal.ClaudeFiles += [pscustomobject]@{ Relative = $relative; File = $stored; SHA256 = (Add-PersonalFile $file.FullName $stored) } }
                catch { Add-ExtraWarning "Claude-Datei nicht gesichert: $($file.FullName): $_" }
            }
        }
    } catch { Add-ExtraWarning "Claude-Code-Memories und -Einstellungen konnten nicht vollständig gesichert werden: $_" }
}
# Reference files for manual restore; power plans and app associations need an elevated backup.
try {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path -LiteralPath $hosts -PathType Leaf) { $null = Add-PersonalFile $hosts 'Personal\Reference\hosts'; $personal.References += [pscustomobject]@{ Name = 'hosts'; File = 'Personal\Reference\hosts'; Status = 'Exported' } }
} catch { Add-ExtraWarning "hosts-Datei konnte nicht gesichert werden: $_" }
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $referenceRoot = Join-SetupSafePath $BackupPath 'Personal\Reference'
    New-Item -ItemType Directory -Path $referenceRoot -Force | Out-Null
    try {
        $scheme = [regex]::Match([string](& powercfg.exe /getactivescheme), '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
        if (-not $scheme) { throw 'Aktiver Energieplan nicht erkannt.' }
        $null = & powercfg.exe /export (Join-Path $referenceRoot 'power-scheme.pow') $scheme 2>&1
        if ((Get-Item -LiteralPath (Join-Path $referenceRoot 'power-scheme.pow') -ErrorAction Stop).Length -eq 0) { throw "powercfg Exitcode $LASTEXITCODE" }
        $personal.References += [pscustomobject]@{ Name = 'PowerScheme'; File = 'Personal\Reference\power-scheme.pow'; Status = 'Exported' }
    } catch { Add-ExtraWarning "Energieplan konnte nicht exportiert werden: $_" }
    try {
        $null = & dism.exe /Online "/Export-DefaultAppAssociations:$(Join-Path $referenceRoot 'app-associations.xml')" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "DISM Exitcode $LASTEXITCODE" }
        $personal.References += [pscustomobject]@{ Name = 'AppAssociations'; File = 'Personal\Reference\app-associations.xml'; Status = 'Exported' }
    } catch { Add-ExtraWarning "Standard-App-Zuordnungen konnten nicht exportiert werden: $_" }
} else {
    Write-Host 'Energieplan und Standard-App-Zuordnungen wurden übersprungen: Dafür sind Administratorrechte erforderlich.'
}
Write-SetupJson $personal (Join-Path $BackupPath 'personal-settings.json')

[pscustomobject]@{ WarningCount = $warnings.Count; Warnings = @($warnings); EnvironmentCount = $environment.Count
    FeatureCount = $features.Count + $capabilities.Count; PrinterCount = $printers.Count; DriveCount = $drives.Count
    ExtensionCount = @($developer.VSCodeProducts | ForEach-Object { $_.Extensions }).Count; ModuleCount = @($developer.PowerShellModules).Count
    ChocolateyCount = @($chocolatey.Packages).Count; FontCount = @($personal.Fonts).Count
    WlanCount = @($personal.WlanProfiles).Count; SshCount = @($personal.SshFiles).Count; ClaudeCount = @($personal.ClaudeFiles).Count }

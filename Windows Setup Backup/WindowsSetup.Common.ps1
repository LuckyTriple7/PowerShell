#requires -Version 5.1
# Shared helpers. Run Backup-WindowsSetup.ps1 or Restore-WindowsSetup.ps1.
$script:SetupBackupVersion = '1.2.0.0'
function Write-SetupJson {
    param($Value, [string]$Path)
    ConvertTo-Json -InputObject $Value -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-SetupSevenZipPath {
    foreach ($candidate in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $command = Get-Command 7z.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Assert-SetupArchivePassword {
    param([string]$Value)
    # 7-Zip's own command-line parser treats every " as a quote toggle, so -p can never carry one.
    if ($Value.Contains('"')) { throw 'Das Archivpasswort darf kein Anfuehrungszeichen (") enthalten, weil 7-Zip es ueber die Kommandozeile nicht verarbeiten kann.' }
}

function Get-SetupChocolateyPath {
    foreach ($candidate in @("$env:ChocolateyInstall\bin\choco.exe", "$env:LOCALAPPDATA\UniGetUI\Chocolatey\bin\choco.exe", "$env:ProgramData\chocolatey\bin\choco.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $command = Get-Command choco.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-SetupLocations {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    [ordered]@{
        StartMenuUser = @{ Path = [Environment]::GetFolderPath('Programs'); Filter = '*.lnk','*.url'; Developer = $false }
        StartMenuCommon = @{ Path = [Environment]::GetFolderPath('CommonPrograms'); Filter = '*.lnk','*.url'; Developer = $false }
        PowerShell5 = @{ Path = Join-Path $documents 'WindowsPowerShell'; Filter = '*profile.ps1'; Developer = $true }
        PowerShell7 = @{ Path = Join-Path $documents 'PowerShell'; Filter = '*profile.ps1'; Developer = $true }
        Git = @{ Path = $env:USERPROFILE; Filter = '.gitconfig','.gitignore_global'; Developer = $true }
        VSCode = @{ Path = Join-Path $env:APPDATA 'Code\User'; Filter = 'settings.json','keybindings.json'; Developer = $true }
        VSCodeSnippets = @{ Path = Join-Path $env:APPDATA 'Code\User\snippets'; Filter = '*'; Developer = $true }
        Terminal = @{ Path = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'; Filter = 'settings.json'; Developer = $true }
        TerminalUnpackaged = @{ Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal'; Filter = 'settings.json'; Developer = $true }
    }
}

function Get-SetupRegistrySpec {
    @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Names = @('HideFileExt','Hidden','ShowSuperHidden','LaunchTo','TaskbarAl','ShowTaskViewButton') }
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Names = @('AppsUseLightTheme','SystemUsesLightTheme','EnableTransparency') }
    )
}

function Get-SetupRegistryValues {
    foreach ($spec in Get-SetupRegistrySpec) {
        if (Test-Path -LiteralPath $spec.Path) {
            $key = Get-Item -LiteralPath $spec.Path
            foreach ($name in $spec.Names) {
                if ($key.GetValueNames() -contains $name -and $key.GetValueKind($name) -eq 'DWord') {
                    [pscustomobject]@{ Path = $spec.Path; Name = $name; Value = $key.GetValue($name); Type = 'DWord' }
                }
            }
        }
    }
}

function Join-SetupSafePath {
    param([string]$Root, [string]$Relative)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) { throw "Ungueltiger relativer Pfad: $Relative" }
    $result = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $result.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Pfad verlaesst den Zielordner: $Relative" }
    return $result
}

function Assert-SetupNoReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and $item.LinkType) {
                throw "Verknüpfte Pfadkomponente ist für die Wiederherstellung nicht zulässig: $current"
            }
        }
        $parent = Split-Path -Path $current -Parent
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-SetupDocumentSchema {
    param($Document, [string]$Name)
    if ($null -eq $Document -or $Document.SchemaVersion -ne 1) { throw "Unbekannte oder fehlende Schemaversion: $Name" }
}

function Test-SetupFileAllowed {
    param([string]$Key, [string]$Relative, $Location)
    if ($Key -notin @('StartMenuUser','StartMenuCommon','VSCodeSnippets') -and $Relative -match '[/\\]') { return $false }
    foreach ($pattern in $Location.Filter) {
        if ([IO.Path]::GetFileName($Relative) -like $pattern) { return $true }
    }
    return $false
}

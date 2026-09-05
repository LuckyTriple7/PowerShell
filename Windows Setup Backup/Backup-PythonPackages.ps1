#requires -Version 5.1
<#
.SYNOPSIS
Exportiert pip-Pakete je gefundener oder explizit angegebener Python-Umgebung.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [string[]]$PythonExecutables = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.Common.ps1')

function Invoke-PythonRead {
    param([string]$Executable, [string[]]$Arguments, [string]$ErrorLog)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Executable @Arguments 2> $ErrorLog)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne 0) { throw "Python-Aufruf fehlgeschlagen (Exitcode $code). Details: $ErrorLog" }
    return ($output -join [Environment]::NewLine)
}

$root = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $root) { throw "Python-Sicherungsordner existiert bereits: $root" }
New-Item -ItemType Directory -Path $root | Out-Null
$candidates = @(
    foreach ($command in @(Get-Command python.exe, python3.exe -All -ErrorAction SilentlyContinue)) {
        # Store execution aliases may open the Store instead of running Python.
        if ($command.Source -and $command.Source -notlike '*\Microsoft\WindowsApps\*') { $command.Source }
    }
    $installationRoot = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path -LiteralPath $installationRoot) {
        foreach ($directory in Get-ChildItem -LiteralPath $installationRoot -Directory) {
            $candidate = Join-Path $directory.FullName 'python.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
        }
    }
    foreach ($extra in $PythonExecutables) { [IO.Path]::GetFullPath($extra) }
) | Sort-Object -Unique

$environments = [Collections.Generic.List[object]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$index = 0
foreach ($executable in $candidates) {
    $index++
    $id = 'python-{0:d2}' -f $index
    $environmentRoot = Join-Path $root $id
    New-Item -ItemType Directory -Path $environmentRoot | Out-Null
    $entry = [ordered]@{ Id = $id; Executable = $executable; Version = $null; Status = 'Failed'; PackageCount = 0; SHA256 = $null; Error = $null }
    Write-Host "  [Python $index/$(@($candidates).Count)] $executable"
    try {
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Interpreter fehlt: $executable" }
        $entry.Version = Invoke-PythonRead $executable @('--version') (Join-Path $environmentRoot 'version-errors.log')
        $inventoryText = Invoke-PythonRead $executable @('-m','pip','--disable-pip-version-check','--no-input','list','--format=json') (Join-Path $environmentRoot 'pip-list-errors.log')
        # In Windows PowerShell 5.1 ConvertFrom-Json emits the JSON array as one
        # pipeline object. Assign first to avoid nesting it in another array.
        $packages = $inventoryText | ConvertFrom-Json
        $packages = @($packages)
        Write-SetupJson -Value $packages -Path (Join-Path $environmentRoot 'packages.json')
        $requirements = Invoke-PythonRead $executable @('-m','pip','--disable-pip-version-check','--no-input','freeze','--all') (Join-Path $environmentRoot 'pip-freeze-errors.log')
        $requirementsPath = Join-Path $environmentRoot 'requirements.txt'
        # UTF-8 without BOM is portable across pip versions.
        [IO.File]::WriteAllText($requirementsPath, $requirements + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $entry.PackageCount = $packages.Count
        $entry.SHA256 = (Get-FileHash -LiteralPath $requirementsPath -Algorithm SHA256).Hash
        $entry.Status = 'Exported'
        Write-Host "    $($entry.Version): $($entry.PackageCount) Pakete exportiert."
        if ($requirements -match '(?m)^\s*(-e\s|[^#\r\n]+\s@\s)') {
            $message = "${id}: Lokale/editierbare oder URL-basierte Pakete enthalten. Quellordner und Erreichbarkeit fuer die Wiederherstellung pruefen."
            $warnings.Add($message)
            Write-Warning $message
        }
    } catch {
        $entry.Error = $_.Exception.Message
        $message = "${id}: Keine vollstaendige pip-Sicherung fuer $executable. $($entry.Error) Eine Python-Umgebung kann auch ohne pip existieren."
        $warnings.Add($message)
        Write-Warning $message
    }
    $environments.Add([pscustomobject]$entry)
}
if (@($candidates).Count -eq 0) { Write-Host '  Keine Python-Interpreter gefunden. Weitere Pfade mit -PythonExecutables angeben.' }
Write-SetupJson -Value @{ SchemaVersion = 1; Environments = @($environments.ToArray()); Warnings = @($warnings.ToArray()) } -Path (Join-Path $root 'environments.json')
$exported = @($environments | Where-Object Status -eq 'Exported')
[pscustomobject]@{
    FoundCount = $environments.Count; ExportedCount = $exported.Count
    PackageCount = [int](($exported | Measure-Object PackageCount -Sum).Sum)
    Warnings = @($warnings.ToArray())
}

#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WindowsSetup.GuiSupport.ps1')

$failures = [Collections.Generic.List[string]]::new()
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "PASS: $Name" -ForegroundColor Green }
    catch { $failures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL: ${Name}: $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsSetupTests-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop | Out-Null
    $backup = Join-Path $testRoot 'FixtureBackup'
    New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
    Save-SetupDocument ([ordered]@{
        SchemaVersion = 1; ApplicationVersion = $script:SetupBackupVersion; Created = (Get-Date).ToString('o'); Computer = 'TEST-PC'
        User = 'test'; OriginalProfile = 'C:\DifferentProfile'; WingetReady = $false; StartLayoutReady = $false
        CustomFolders = @(); Files = @(); Warnings = @()
    }) (Join-Path $backup 'manifest.json')
    Save-SetupDocument @() (Join-Path $backup 'settings-registry.json')

    Test-Case 'Legacy backup request defaults' {
        $legacy = [pscustomobject]@{
            SchemaVersion = 1; Operation = 'Backup'; Destination = (Join-Path $testRoot 'Destination')
            IncludeDeveloperSettings = $false; SkipWinget = $true; AcceptSourceAgreements = $false; SkipPython = $true
        }
        Test-SetupRequest $legacy
    }

    $restore = [pscustomobject]@{
        SchemaVersion = 1; Operation = 'Restore'; BackupPath = $backup; Preview = $true
        Programs = $false; Settings = $true; Shortcuts = $false; IncludeCommonStartMenu = $false
        UseSavedVersions = $false; AcceptAgreements = $false; PythonPackages = $false
        PackageIds = [string[]]@(); CustomFolderKeys = [string[]]@(); StorePackageFamilies = [string[]]@(); ChocolateyPackages = [string[]]@()
        VSCodeExtensions = $false; PowerShellModules = $false; UserEnvironment = $false; MachineEnvironment = $false
        WindowsComponents = $false; Connections = $false; EnvironmentId = ''; PythonExecutable = ''; ProtectedArchivePassword = ''
    }

    Test-Case 'Empty selections serialize as arrays' {
        $json = ConvertTo-Json $restore -Depth 8
        Assert-True ($json -notmatch '"(PackageIds|CustomFolderKeys|StorePackageFamilies|ChocolateyPackages)"\s*:\s*\{') 'Eine leere Auswahl wurde als Objekt serialisiert.'
        Test-SetupRequest ($json | ConvertFrom-Json)
    }

    Test-Case 'String boolean is rejected' {
        $invalid = $restore | Select-Object *
        $invalid.Programs = 'false'
        try { Test-SetupRequest $invalid; throw 'String-Boolean wurde akzeptiert.' }
        catch { if ($_.Exception.Message -notlike 'Auftragsfeld muss true oder false sein:*') { throw } }
    }

    Test-Case 'Null preview is rejected' {
        $invalid = $restore | Select-Object *
        $invalid.Preview = $null
        try { Test-SetupRequest $invalid; throw 'Preview null wurde akzeptiert.' }
        catch { if ($_.Exception.Message -notlike 'Boolesches Pflichtfeld fehlt im Wiederherstellungsauftrag:*') { throw } }
    }

    Test-Case 'Archive traversal is rejected' {
        try { Assert-SetupArchiveEntryPath '..\escape.txt' (Join-Path $testRoot 'Extract'); throw 'Traversal-Pfad wurde akzeptiert.' }
        catch { if ($_.Exception.Message -notlike 'Archiveintrag * Zielverzeichnis:*') { throw } }
    }

    Test-Case 'Traversal ZIP is not extracted' {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = Join-Path $testRoot 'Traversal.zip'
        $stream = [IO.File]::Open($archive, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry('../escape.txt')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('blocked') } finally { $writer.Dispose() }
        } finally { $zip.Dispose(); $stream.Dispose() }
        $destination = Join-Path $testRoot 'TraversalExtract'
        try { Expand-SetupZipBackup $archive $destination; throw 'Traversal-ZIP wurde entpackt.' }
        catch { if ($_.Exception.Message -notlike 'Archiveintrag * Zielverzeichnis:*') { throw } }
        Assert-True (-not (Test-Path -LiteralPath $destination)) 'Fehlgeschlagenes Entpackziel blieb liegen.'
    }

    Test-Case 'Unknown document schema is rejected' {
        try { Assert-SetupDocumentSchema ([pscustomobject]@{ SchemaVersion = 999 }) 'test.json'; throw 'Unbekanntes Schema wurde akzeptiert.' }
        catch { if ($_.Exception.Message -notlike 'Unbekannte oder fehlende Schemaversion:*') { throw } }
    }

    Test-Case 'Chocolatey version capture preserves native exit code' {
        $choco = Get-SetupChocolateyPath
        if (-not $choco) { return }
        $versionLines = @(& $choco --version 2>&1)
        $versionExit = $LASTEXITCODE
        $version = [string]($versionLines | Select-Object -First 1)
        Assert-True ($versionExit -eq 0) "Chocolatey-Versionserkennung meldete Exitcode $versionExit."
        Assert-True (-not [string]::IsNullOrWhiteSpace($version)) 'Chocolatey lieferte keine Version.'
    }

    Test-Case 'Direct folder backup publishes a valid result' {
        $destination = Join-Path $testRoot 'DirectBackup'
        $output = & (Join-Path $PSScriptRoot 'Backup-WindowsSetup.ps1') -Destination $destination -SkipWinget -SkipPython -SkipChocolatey 3>$null
        $backupResult = @($output | Where-Object { $_.PSObject.Properties['BackupPath'] })
        Assert-True ($backupResult.Count -eq 1) 'Direktes Backup lieferte kein eindeutiges Ergebnisobjekt.'
        Assert-True (Test-Path -LiteralPath (Join-Path $backupResult[0].BackupPath 'manifest.json') -PathType Leaf) 'Veröffentlichtes Ordner-Backup enthält kein Manifest.'
        Assert-True (@(Get-ChildItem -LiteralPath $destination -Filter '.wsb-*' -Force).Count -eq 0) 'Temporärer Veröffentlichungsname blieb liegen.'
    }

    Test-Case 'Direct ZIP backup publishes a readable archive' {
        $destination = Join-Path $testRoot 'DirectZipBackup'
        $output = & (Join-Path $PSScriptRoot 'Backup-WindowsSetup.ps1') -Destination $destination -SkipWinget -SkipPython -SkipChocolatey -CreateArchive 3>$null
        $backupResult = @($output | Where-Object { $_.PSObject.Properties['BackupPath'] })
        Assert-True ($backupResult.Count -eq 1) 'Direktes ZIP-Backup lieferte kein eindeutiges Ergebnisobjekt.'
        Assert-True ([IO.Path]::GetExtension($backupResult[0].BackupPath) -eq '.zip') 'Veröffentlichtes Backup ist kein ZIP.'
        $manifest = Read-SetupBackupDocument $backupResult[0].BackupPath 'manifest.json'
        Assert-True ($manifest.SchemaVersion -eq 1) 'Veröffentlichtes ZIP-Manifest ist nicht lesbar.'
        Assert-True (@(Get-ChildItem -LiteralPath $destination -Filter '.wsb-*' -Force).Count -eq 0) 'Temporärer ZIP-Veröffentlichungsname blieb liegen.'
    }

    Test-Case 'Archive password with quote is rejected' {
        try { Assert-SetupArchivePassword 'ab"cd'; throw 'Passwort mit Anfuehrungszeichen wurde akzeptiert.' }
        catch { if ($_.Exception.Message -like '*wurde akzeptiert*') { throw } }
        Assert-SetupArchivePassword 'a b\ c\\'
    }

    Test-Case 'Direct 7z backup opens with the literal password' {
        $sevenZipPath = Get-SetupSevenZipPath
        if (-not $sevenZipPath) { Write-Host 'SKIP: 7-Zip nicht installiert.' -ForegroundColor Yellow; return }
        $password = 'a b\ ' + [char]0x00C4 + [char]0x20AC + ' c\\'
        $destination = Join-Path $testRoot 'DirectSevenZipBackup'
        $output = & (Join-Path $PSScriptRoot 'Backup-WindowsSetup.ps1') -Destination $destination -SkipWinget -SkipPython -SkipChocolatey -CreateArchive -ArchivePassword $password 3>$null
        $backupResult = @($output | Where-Object { $_.PSObject.Properties['BackupPath'] })
        Assert-True ($backupResult.Count -eq 1) 'Direktes 7z-Backup lieferte kein eindeutiges Ergebnisobjekt.'
        $archive = $backupResult[0].BackupPath
        Assert-True ([IO.Path]::GetExtension($archive) -eq '.7z') 'Veroeffentlichtes Backup ist kein 7z.'
        $manifest = Read-SetupBackupDocument $archive 'manifest.json' $password
        Assert-True ($manifest.SchemaVersion -eq 1) 'Veroeffentlichtes 7z-Manifest ist nicht lesbar.'
        # Independent check: quote only the spaces, so no parser can reinterpret backslashes.
        $startInfo = [Diagnostics.ProcessStartInfo]::new($sevenZipPath, ('t -y -p' + $password.Replace(' ', '" "') + ' "' + $archive + '"'))
        $startInfo.UseShellExecute = $false; $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        $null = $process.StandardOutput.ReadToEnd(); $null = $process.StandardError.ReadToEnd(); $process.WaitForExit()
        Assert-True ($process.ExitCode -eq 0) "7-Zip lehnte das woertliche Passwort ab (Exitcode $($process.ExitCode))."
    }

    Test-Case 'ZIP preview cleans extraction and reports warnings' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = Join-Path $testRoot 'FixtureBackup.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($backup, $archive, [IO.Compression.CompressionLevel]::Optimal, $false)
        $restore.BackupPath = $archive
        $requestPath = Join-Path $testRoot 'request.json'
        $run = Join-Path $testRoot 'run'
        Save-SetupDocument $restore $requestPath
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-WindowsSetupJob.ps1') -RequestPath $requestPath -RunDirectory $run
        $code = $LASTEXITCODE
        $result = Read-SetupDocument (Join-Path $run 'result.json')
        Assert-True ($code -eq 2) "Warnende Vorschau lieferte Exitcode $code statt 2."
        Assert-True ($result.Status -eq 'PreviewCompletedWithWarnings') "Unerwarteter Status: $($result.Status)"
        Assert-True ($result.WarningCount -eq 1) "Unerwartete Warnungsanzahl: $($result.WarningCount)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $run 'ExpandedBackup'))) 'Temporär entpacktes Backup blieb liegen.'
        $operationLog = Get-Content -LiteralPath (Join-Path $run 'operation.log') -Raw
        Assert-True ($operationLog -like '*WindowsSetupRestore-*') 'Archiv wurde nicht im lokalen Temp-Bereich verarbeitet.'
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Host "Alle Tests bestanden." -ForegroundColor Green

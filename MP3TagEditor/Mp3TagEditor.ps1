<#
    MP3 Tag Editor – einfaches WinForms-GUI zum Bearbeiten von ID3-Tags
    und Album-Covern mehrerer MP3s, ohne jede Datei extern anklicken zu müssen.

    Benötigt: TagLibSharp.dll (liegt im selben Ordner) und PowerShell 5.1 (STA).
    Start am besten über Start.cmd.

    Version: 0.1.0.0
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- TagLibSharp laden ---------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dllPath   = Join-Path $scriptDir 'TagLibSharp.dll'
if (-not (Test-Path $dllPath)) {
    [System.Windows.Forms.MessageBox]::Show("TagLibSharp.dll nicht gefunden:`n$dllPath", 'Fehler',
        'OK', 'Error') | Out-Null
    return
}
# Aus Bytes laden, damit die DLL nicht von Windows gesperrt wird
[System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($dllPath)) | Out-Null

# --- Hilfsfunktionen -----------------------------------------------------------

# Entfernt Klammer-Zusätze wie (Official Video) / [Lyrics] aus einem Titel,
# behält aber musikalisch relevante Zusätze wie (Remix) / (Radio Edit).
function Clean-NamePart([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $junk = '(?i)\b(official|video|videoclip|lyrics?|audio|visualizer|hd|4k|uhd|' +
            'tradu[cç][aã]o|tiktok|enhanced|music\s+video|live\s+performance|lyric\s+video)\b'
    # Klammer-/eckige Gruppen entfernen, die Junk enthalten
    $result = [regex]::Replace($text, '[\(\[][^\)\]]*[\)\]]', {
        param($m)
        if ($m.Value -match $junk) { '' } else { $m.Value }
    })
    # Mehrfache Leerzeichen + Reste aufräumen
    $result = ($result -replace '\s{2,}', ' ').Trim()
    $result = $result.Trim(@(' ', '-', "`t"))
    return $result.Trim()
}

# Zerlegt "Interpret - Titel" aus dem Dateinamen.
function Parse-FileName([string]$baseName) {
    $artist = ''
    $title  = $baseName
    # Erstes " - " als Trenner
    $idx = $baseName.IndexOf(' - ')
    if ($idx -gt 0) {
        $artist = $baseName.Substring(0, $idx)
        $title  = $baseName.Substring($idx + 3)
    }
    return [PSCustomObject]@{
        Artist = (Clean-NamePart $artist)
        Title  = (Clean-NamePart $title)
    }
}

# Bytes -> Bitmap für die Vorschau (ohne die Datei zu sperren)
function Load-ImageFromBytes([byte[]]$bytes) {
    if (-not $bytes -or $bytes.Length -eq 0) { return $null }
    try {
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $img = [System.Drawing.Image]::FromStream($ms)
        return $img
    } catch { return $null }
}

# Lädt Bytes von einer URL (für Online-Cover)
function Download-Bytes([string]$url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mp3TagEditor/1.0 ( luckytriple7@gmail.com )')
        return $wc.DownloadData($url)
    } catch { return $null }
}

# Sucht Cover-Kandidaten: zuerst iTunes, bei 0 Treffern MusicBrainz/Cover Art Archive.
# Liefert Objekte mit Label / Thumb (kleine Vorschau-URL) / Url (großes Bild) / Source.
function Search-CoverCandidates([string]$artist, [string]$title) {
    $q = (("$artist $title").Trim())
    $out = @()
    if ([string]::IsNullOrWhiteSpace($q)) { return $out }

    # 1) iTunes
    try {
        $term = [uri]::EscapeDataString($q)
        $u = "https://itunes.apple.com/search?term=$term&media=music&entity=song&limit=12"
        $r = Invoke-RestMethod -Uri $u -TimeoutSec 15
        foreach ($it in $r.results) {
            if (-not $it.artworkUrl100) { continue }
            $big = $it.artworkUrl100 -replace '100x100bb', '600x600bb'
            $out += [PSCustomObject]@{
                Label  = ('{0} – {1}  [{2}]' -f $it.artistName, $it.trackName, $it.collectionName)
                Thumb  = $it.artworkUrl100
                Url    = $big
                Source = 'iTunes'
            }
        }
    } catch {}

    if ($out.Count -gt 0) { return $out }

    # 2) Fallback: MusicBrainz -> Cover Art Archive
    try {
        $mbq = [uri]::EscapeDataString(('artist:"{0}" AND recording:"{1}"' -f $artist, $title))
        $mu = "https://musicbrainz.org/ws/2/release?query=$mbq&fmt=json&limit=8"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mp3TagEditor/1.0 ( luckytriple7@gmail.com )')
        $json = $wc.DownloadString($mu) | ConvertFrom-Json
        foreach ($rel in $json.releases) {
            $front = "https://coverartarchive.org/release/$($rel.id)/front-500"
            $out += [PSCustomObject]@{
                Label  = ('{0} – {1}  [{2}]' -f ($rel.'artist-credit'.name -join ', '), $rel.title, $rel.date)
                Thumb  = $front
                Url    = $front
                Source = 'MusicBrainz'
            }
            if ($out.Count -ge 8) { break }
        }
    } catch {}

    return $out
}

# Auswahldialog: zeigt Kandidaten als Liste + Vorschau. Gibt die Bytes des
# gewählten Covers zurück oder $null bei Abbruch.
function Show-CoverPicker([array]$candidates) {
    if (-not $candidates -or $candidates.Count -eq 0) { return $null }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Cover auswählen'
    $dlg.Size = New-Object System.Drawing.Size(720, 440)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = New-Object System.Drawing.Point(12, 12)
    $lb.Size = New-Object System.Drawing.Size(380, 340)
    foreach ($c in $candidates) { [void]$lb.Items.Add(('[{0}] {1}' -f $c.Source, $c.Label)) }
    $dlg.Controls.Add($lb)

    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point(404, 12)
    $pic.Size = New-Object System.Drawing.Size(280, 280)
    $pic.BorderStyle = 'FixedSingle'
    $pic.SizeMode = 'Zoom'
    $pic.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    $dlg.Controls.Add($pic)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Location = New-Object System.Drawing.Point(404, 298)
    $lblHint.Size = New-Object System.Drawing.Size(280, 40)
    $lblHint.Text = 'Eintrag wählen – Vorschau erscheint rechts.'
    $dlg.Controls.Add($lblHint)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Übernehmen'
    $btnOk.Location = New-Object System.Drawing.Point(404, 362)
    $btnOk.Size = New-Object System.Drawing.Size(135, 32)
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.Add($btnOk)
    $dlg.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Abbrechen'
    $btnCancel.Location = New-Object System.Drawing.Point(549, 362)
    $btnCancel.Size = New-Object System.Drawing.Size(135, 32)
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel

    $lb.Add_SelectedIndexChanged({
        $i = $lb.SelectedIndex
        if ($i -lt 0) { return }
        $lblHint.Text = 'Lade Vorschau...'; $lblHint.Refresh()
        $b = Download-Bytes $candidates[$i].Thumb
        if ($pic.Image) { $pic.Image.Dispose(); $pic.Image = $null }
        if ($b) { $pic.Image = Load-ImageFromBytes $b; $lblHint.Text = ("Quelle: " + $candidates[$i].Source) }
        else    { $lblHint.Text = 'Keine Vorschau verfügbar.' }
    })
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }

    $res = $dlg.ShowDialog()
    $chosen = $lb.SelectedIndex
    $dlg.Dispose()
    if ($res -ne 'OK' -or $chosen -lt 0) { return $null }
    # Großes Bild laden
    return (Download-Bytes $candidates[$chosen].Url)
}

# Vorschau-Dialog für die Titel-Bereinigung: Liste mit Alt/Neu + Häkchen.
# Gibt die bestätigten Aenderungen zurück (oder leeres Array bei Abbruch).
function Show-TitleCleanupPreview([array]$changes) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Titel bereinigen – Vorschau'
    $dlg.Size = New-Object System.Drawing.Size(840, 520)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false

    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(12, 10)
    $info.Size = New-Object System.Drawing.Size(800, 20)
    $info.Text = 'Nur angehakte Titel werden geändert. Dateinamen bleiben unverändert.'
    $dlg.Controls.Add($info)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(12, 34)
    $lv.Size = New-Object System.Drawing.Size(806, 396)
    $lv.View = 'Details'
    $lv.CheckBoxes = $true
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.Anchor = 'Top,Bottom,Left,Right'
    [void]$lv.Columns.Add('Alt', 390)
    [void]$lv.Columns.Add('Neu', 390)
    foreach ($c in $changes) {
        $item = New-Object System.Windows.Forms.ListViewItem($c.Old)
        [void]$item.SubItems.Add($c.New)
        $item.Checked = $true
        [void]$lv.Items.Add($item)
    }
    $dlg.Controls.Add($lv)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Angehakte übernehmen'
    $btnOk.Location = New-Object System.Drawing.Point(580, 444)
    $btnOk.Size = New-Object System.Drawing.Size(170, 32)
    $btnOk.Anchor = 'Bottom,Right'
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.Add($btnOk); $dlg.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Abbrechen'
    $btnCancel.Location = New-Object System.Drawing.Point(756, 444)
    $btnCancel.Size = New-Object System.Drawing.Size(62, 32)
    $btnCancel.Anchor = 'Bottom,Right'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel); $dlg.CancelButton = $btnCancel

    $res = $dlg.ShowDialog()
    $approved = @()
    if ($res -eq 'OK') {
        for ($i = 0; $i -lt $lv.Items.Count; $i++) {
            if ($lv.Items[$i].Checked) { $approved += $changes[$i] }
        }
    }
    $dlg.Dispose()
    return $approved
}

# Stapel: entfernt aus dem TITEL-Tag Klammer-Zusätze wie (Official Music Video).
# Wirkt auf markierte Dateien (mehrere) bzw. sonst auf alle. Dateinamen bleiben.
function Invoke-TitleCleanup {
    $targets = @()
    if ($lstFiles.SelectedIndices.Count -gt 1) {
        foreach ($idx in $lstFiles.SelectedIndices) { $targets += $script:files[$idx] }
    } else {
        $targets = $script:files
    }
    if (-not $targets -or $targets.Count -eq 0) { Set-Status 'Keine Dateien geladen.'; return }

    Set-Status 'Prüfe Titel...'
    $changes = @()
    foreach ($pth in $targets) {
        try {
            $tf = [TagLib.File]::Create($pth)
            $old = [string]$tf.Tag.Title
            $tf.Dispose()
            if ([string]::IsNullOrWhiteSpace($old)) { continue }
            $new = Clean-NamePart $old
            if ($new -and $new -ne $old) {
                $changes += [PSCustomObject]@{ Path = $pth; Old = $old; New = $new }
            }
        } catch {}
    }
    if ($changes.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Keine Titel mit entfernbaren Zusätzen gefunden.',
            'Titel bereinigen', 'OK', 'Information') | Out-Null
        Set-Status 'Titel bereinigen: nichts zu tun.'
        return
    }

    $approved = Show-TitleCleanupPreview $changes
    if (-not $approved -or $approved.Count -eq 0) { Set-Status 'Titel bereinigen abgebrochen.'; return }

    $ok = 0; $fail = 0
    foreach ($c in $approved) {
        try {
            $tf = [TagLib.File]::Create($c.Path)
            $tf.Tag.Title = $c.New
            $tf.Save(); $tf.Dispose()
            $ok++
        } catch { $fail++ }
    }
    if ($script:currentPath) { Load-File $script:currentPath }
    Set-Status ("Titel bereinigt: $ok geändert, $fail Fehler (Dateinamen unverändert).")
}

# Assistent: geht alle Dateien OHNE Cover durch, sucht je Datei online,
# lässt dich eins auswählen, speichert es und springt zur nächsten Datei.
function Invoke-MissingCoverWizard {
    if (-not $script:files -or $script:files.Count -eq 0) { Set-Status 'Keine Dateien geladen.'; return }
    $missing = @()
    foreach ($pth in $script:files) {
        $has = $false
        try { $tf = [TagLib.File]::Create($pth); $has = ($tf.Tag.Pictures -and $tf.Tag.Pictures.Length -gt 0); $tf.Dispose() } catch {}
        if (-not $has) { $missing += $pth }
    }
    if ($missing.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Alle Dateien haben bereits ein Cover.','Cover-Assistent','OK','Information') | Out-Null
        return
    }
    $done = 0; $skip = 0; $idx = 0
    foreach ($pth in $missing) {
        $idx++
        # Datei in der Liste anzeigen/laden (für Kontext im Editor)
        $li = [array]::IndexOf($script:files, $pth)
        if ($li -ge 0) { $lstFiles.ClearSelected(); $lstFiles.SelectedIndex = $li } else { Load-File $pth }

        # Suchbegriff aus Tag, sonst aus Dateiname
        $artist = $txt['Artist'].Text.Trim()
        $title  = $txt['Title'].Text.Trim()
        if (-not $artist -and -not $title) {
            $parsed = Parse-FileName ([System.IO.Path]::GetFileNameWithoutExtension($pth))
            $artist = $parsed.Artist; $title = $parsed.Title
        }
        Set-Status ("Fehlende Cover {0}/{1}: {2}" -f $idx, $missing.Count, (Split-Path $pth -Leaf))

        $form.Cursor = 'WaitCursor'
        try { $cands = Search-CoverCandidates $artist $title } finally { $form.Cursor = 'Default' }

        $bytes = $null
        if ($cands -and $cands.Count -gt 0) {
            $bytes = Show-CoverPicker $cands
            if (-not $bytes) {
                $r = [System.Windows.Forms.MessageBox]::Show('Diese Datei übersprungen. Assistent fortsetzen?','Weiter?','YesNoCancel','Question')
                if ($r -ne 'Yes') { break }
                $skip++; continue
            }
        } else {
            $r = [System.Windows.Forms.MessageBox]::Show(
                ("Kein Online-Cover gefunden für:`n{0}`n`nJa = Bild aus Datei wählen`nNein = überspringen`nAbbrechen = Assistent beenden" -f (Split-Path $pth -Leaf)),
                'Kein Treffer','YesNoCancel','Question')
            if ($r -eq 'Cancel') { break }
            if ($r -eq 'No') { $skip++; continue }
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'Bilder (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png|Alle Dateien (*.*)|*.*'
            if (Test-Path $txtFolder.Text) { $dlg.InitialDirectory = $txtFolder.Text }
            if ($dlg.ShowDialog() -eq 'OK') { $bytes = [System.IO.File]::ReadAllBytes($dlg.FileName) } else { $skip++; continue }
        }

        # Cover speichern
        try {
            $tf = [TagLib.File]::Create($pth)
            $pic = New-Object TagLib.Picture (New-Object TagLib.ByteVector(,$bytes))
            $pic.Type = [TagLib.PictureType]::FrontCover
            $pic.Description = 'Cover'
            $tf.Tag.Pictures = @($pic)
            $tf.Save(); $tf.Dispose()
            Refresh-ListMarker $pth
            if ($script:currentPath -eq $pth) {
                if ($picCover.Image) { $picCover.Image.Dispose() }
                $picCover.Image = Load-ImageFromBytes $bytes
                $script:pendingCover = $null; $script:removeCover = $false
            }
            $done++
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Speichern fehlgeschlagen','OK','Error') | Out-Null
        }
    }
    Set-Status ("Cover-Assistent fertig: {0} gesetzt, {1} übersprungen." -f $done, $skip)
}

# --- Zustand -------------------------------------------------------------------
$script:files        = @()        # Liste der MP3-Pfade
$script:currentPath  = $null
$script:pendingCover = $null      # byte[] eines neu gewählten Covers (noch nicht gespeichert)
$script:removeCover  = $false     # Cover beim Speichern entfernen?
$script:loading      = $false     # verhindert Dirty-Markierung beim Befüllen

# --- GUI-Aufbau ----------------------------------------------------------------
$form                = New-Object System.Windows.Forms.Form
$form.Text           = 'MP3 Tag & Cover Editor  v0.1.0.0'
$form.Size           = New-Object System.Drawing.Size(940, 640)
$form.MinimumSize    = New-Object System.Drawing.Size(820, 560)
$form.StartPosition  = 'CenterScreen'
$form.Font           = New-Object System.Drawing.Font('Segoe UI', 9)

# Ordnerzeile
$lblFolder           = New-Object System.Windows.Forms.Label
$lblFolder.Text      = 'Ordner:'
$lblFolder.Location  = New-Object System.Drawing.Point(12, 15)
$lblFolder.AutoSize  = $true
$form.Controls.Add($lblFolder)

$txtFolder           = New-Object System.Windows.Forms.TextBox
$txtFolder.Location  = New-Object System.Drawing.Point(64, 12)
$txtFolder.Size      = New-Object System.Drawing.Size(560, 24)
$txtFolder.Anchor    = 'Top,Left,Right'
$txtFolder.Text      = 'C:\Temp\MP3'
$form.Controls.Add($txtFolder)

$btnBrowse           = New-Object System.Windows.Forms.Button
$btnBrowse.Text      = 'Durchsuchen...'
$btnBrowse.Location  = New-Object System.Drawing.Point(632, 11)
$btnBrowse.Size      = New-Object System.Drawing.Size(110, 26)
$btnBrowse.Anchor    = 'Top,Right'
$form.Controls.Add($btnBrowse)

$btnReload           = New-Object System.Windows.Forms.Button
$btnReload.Text      = 'Neu laden'
$btnReload.Location  = New-Object System.Drawing.Point(748, 11)
$btnReload.Size      = New-Object System.Drawing.Size(90, 26)
$btnReload.Anchor    = 'Top,Right'
$form.Controls.Add($btnReload)

# Dateiliste
$lstFiles            = New-Object System.Windows.Forms.ListBox
$lstFiles.Location   = New-Object System.Drawing.Point(12, 48)
$lstFiles.Size       = New-Object System.Drawing.Size(360, 510)
$lstFiles.Anchor     = 'Top,Bottom,Left'
$lstFiles.IntegralHeight = $false
$lstFiles.SelectionMode = 'MultiExtended'
$form.Controls.Add($lstFiles)

# Rechte Spalte – Cover
$picCover            = New-Object System.Windows.Forms.PictureBox
$picCover.Location   = New-Object System.Drawing.Point(388, 48)
$picCover.Size       = New-Object System.Drawing.Size(200, 200)
$picCover.Anchor     = 'Top,Right'
$picCover.BorderStyle = 'FixedSingle'
$picCover.SizeMode   = 'Zoom'
$picCover.BackColor  = [System.Drawing.Color]::FromArgb(245,245,245)
$form.Controls.Add($picCover)

$btnCover            = New-Object System.Windows.Forms.Button
$btnCover.Text       = 'Cover wählen...'
$btnCover.Location   = New-Object System.Drawing.Point(600, 48)
$btnCover.Size       = New-Object System.Drawing.Size(240, 30)
$btnCover.Anchor     = 'Top,Right'
$form.Controls.Add($btnCover)

$btnCoverSearch      = New-Object System.Windows.Forms.Button
$btnCoverSearch.Text = 'Cover online suchen...'
$btnCoverSearch.Location = New-Object System.Drawing.Point(600, 84)
$btnCoverSearch.Size = New-Object System.Drawing.Size(240, 30)
$btnCoverSearch.Anchor = 'Top,Right'
$form.Controls.Add($btnCoverSearch)

$btnCoverRemove      = New-Object System.Windows.Forms.Button
$btnCoverRemove.Text = 'Cover entfernen'
$btnCoverRemove.Location = New-Object System.Drawing.Point(600, 120)
$btnCoverRemove.Size = New-Object System.Drawing.Size(240, 28)
$btnCoverRemove.Anchor = 'Top,Right'
$form.Controls.Add($btnCoverRemove)

$btnCoverAll         = New-Object System.Windows.Forms.Button
$btnCoverAll.Text    = 'Cover auf alle markierten anwenden'
$btnCoverAll.Location = New-Object System.Drawing.Point(600, 154)
$btnCoverAll.Size    = New-Object System.Drawing.Size(240, 44)
$btnCoverAll.Anchor  = 'Top,Right'
$form.Controls.Add($btnCoverAll)

$btnCleanTitles      = New-Object System.Windows.Forms.Button
$btnCleanTitles.Text = 'Titel von Zusätzen bereinigen...'
$btnCleanTitles.Location = New-Object System.Drawing.Point(600, 200)
$btnCleanTitles.Size = New-Object System.Drawing.Size(240, 28)
$btnCleanTitles.Anchor = 'Top,Right'
$form.Controls.Add($btnCleanTitles)

$btnCoverWizard      = New-Object System.Windows.Forms.Button
$btnCoverWizard.Text = 'Fehlende Cover durchgehen...'
$btnCoverWizard.Location = New-Object System.Drawing.Point(600, 232)
$btnCoverWizard.Size = New-Object System.Drawing.Size(240, 28)
$btnCoverWizard.Anchor = 'Top,Right'
$form.Controls.Add($btnCoverWizard)

# Tag-Felder
$fieldDefs = @(
    @{ Key='Title';       Label='Titel:' },
    @{ Key='Artist';      Label='Interpret:' },
    @{ Key='Album';       Label='Album:' },
    @{ Key='AlbumArtist'; Label='Album-Interpret:' },
    @{ Key='Year';        Label='Jahr:' },
    @{ Key='Genre';       Label='Genre:' },
    @{ Key='Track';       Label='Track-Nr.:' }
)
$txt = @{}
$y = 282
foreach ($fd in $fieldDefs) {
    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = $fd.Label
    $lbl.Location = New-Object System.Drawing.Point(388, ($y + 4))
    $lbl.Size     = New-Object System.Drawing.Size(110, 22)
    $lbl.Anchor   = 'Top,Right'
    $form.Controls.Add($lbl)

    $tb           = New-Object System.Windows.Forms.TextBox
    $tb.Location  = New-Object System.Drawing.Point(502, $y)
    $tb.Size      = New-Object System.Drawing.Size(338, 24)
    $tb.Anchor    = 'Top,Left,Right'
    $form.Controls.Add($tb)
    $txt[$fd.Key] = $tb
    $y += 34
}

# Aktionsbuttons
$btnAutoName         = New-Object System.Windows.Forms.Button
$btnAutoName.Text    = 'Aus Dateiname befüllen'
$btnAutoName.Location = New-Object System.Drawing.Point(388, ($y + 6))
$btnAutoName.Size    = New-Object System.Drawing.Size(190, 30)
$btnAutoName.Anchor  = 'Top,Right'
$form.Controls.Add($btnAutoName)

$btnSave             = New-Object System.Windows.Forms.Button
$btnSave.Text        = 'Speichern'
$btnSave.Location    = New-Object System.Drawing.Point(584, ($y + 6))
$btnSave.Size        = New-Object System.Drawing.Size(120, 30)
$btnSave.Anchor      = 'Top,Right'
$form.Controls.Add($btnSave)

$btnSaveNext         = New-Object System.Windows.Forms.Button
$btnSaveNext.Text    = 'Speichern + Weiter'
$btnSaveNext.Location = New-Object System.Drawing.Point(710, ($y + 6))
$btnSaveNext.Size    = New-Object System.Drawing.Size(130, 30)
$btnSaveNext.Anchor  = 'Top,Right'
$form.Controls.Add($btnSaveNext)

# Statusleiste
$status              = New-Object System.Windows.Forms.Label
$status.Location     = New-Object System.Drawing.Point(12, 572)
$status.Size         = New-Object System.Drawing.Size(910, 22)
$status.Anchor       = 'Bottom,Left,Right'
$status.BorderStyle  = 'Fixed3D'
$status.Text         = 'Bereit.'
$form.Controls.Add($status)

function Set-Status([string]$msg) { $status.Text = $msg; $status.Refresh() }

# --- Logik ---------------------------------------------------------------------

function Reset-Cover {
    if ($picCover.Image) { $picCover.Image.Dispose(); $picCover.Image = $null }
    $script:pendingCover = $null
    $script:removeCover  = $false
}

# Tags der aktuellen Datei in die Felder laden
function Load-File([string]$path) {
    $script:loading = $true
    try {
        Reset-Cover
        $script:currentPath = $path
        foreach ($k in $txt.Keys) { $txt[$k].Text = '' }

        $tf = [TagLib.File]::Create($path)
        $tag = $tf.Tag
        $txt['Title'].Text       = [string]$tag.Title
        $txt['Artist'].Text      = ($tag.Performers   -join '; ')
        $txt['Album'].Text       = [string]$tag.Album
        $txt['AlbumArtist'].Text = ($tag.AlbumArtists -join '; ')
        if ($tag.Year  -gt 0) { $txt['Year'].Text  = [string]$tag.Year }
        $txt['Genre'].Text       = ($tag.Genres -join '; ')
        if ($tag.Track -gt 0) { $txt['Track'].Text = [string]$tag.Track }

        if ($tag.Pictures -and $tag.Pictures.Length -gt 0) {
            $img = Load-ImageFromBytes $tag.Pictures[0].Data.Data
            if ($img) { $picCover.Image = $img }
        }
        $tf.Dispose()
        Set-Status ("Geladen: " + (Split-Path $path -Leaf))
    } catch {
        Set-Status ("Fehler beim Laden: " + $_.Exception.Message)
    } finally {
        $script:loading = $false
    }
}

# Aktuelle Felder + Cover in die Datei schreiben
function Save-Current {
    if (-not $script:currentPath) { return $false }
    try {
        $tf  = [TagLib.File]::Create($script:currentPath)
        $tag = $tf.Tag
        $tag.Title  = $txt['Title'].Text.Trim()
        $tag.Album  = $txt['Album'].Text.Trim()

        $performers = @($txt['Artist'].Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $tag.Performers = [string[]]$performers
        $albumArtists = @($txt['AlbumArtist'].Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $tag.AlbumArtists = [string[]]$albumArtists
        $genres = @($txt['Genre'].Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $tag.Genres = [string[]]$genres

        $yr = 0; [void][int]::TryParse(($txt['Year'].Text.Trim()), [ref]$yr)
        $tag.Year = [uint32]([math]::Max(0, $yr))
        $tr = 0; [void][int]::TryParse(($txt['Track'].Text.Trim()), [ref]$tr)
        $tag.Track = [uint32]([math]::Max(0, $tr))

        if ($script:removeCover) {
            $tag.Pictures = @()
        } elseif ($script:pendingCover) {
            $pic = New-Object TagLib.Picture (New-Object TagLib.ByteVector(,$script:pendingCover))
            $pic.Type = [TagLib.PictureType]::FrontCover
            $pic.Description = 'Cover'
            $tag.Pictures = @($pic)
        }

        $tf.Save()
        $tf.Dispose()
        $script:pendingCover = $null
        $script:removeCover  = $false
        Refresh-ListMarker $script:currentPath
        Set-Status ("Gespeichert: " + (Split-Path $script:currentPath -Leaf))
        return $true
    } catch {
        Set-Status ("Fehler beim Speichern: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Speichern fehlgeschlagen','OK','Error') | Out-Null
        return $false
    }
}

# Markierung (Cover vorhanden?) in der Liste für einen Pfad aktualisieren
function Refresh-ListMarker([string]$path) {
    $i = [array]::IndexOf($script:files, $path)
    if ($i -lt 0) { return }
    $marker = '[ ] '
    try {
        $tf = [TagLib.File]::Create($path)
        if ($tf.Tag.Pictures -and $tf.Tag.Pictures.Length -gt 0) { $marker = '[#] ' }
        $tf.Dispose()
    } catch {}
    $script:loading = $true
    $lstFiles.Items[$i] = $marker + (Split-Path $path -Leaf)
    $script:loading = $false
}

# Ordner einlesen
function Load-Folder([string]$folder) {
    if (-not (Test-Path $folder)) {
        Set-Status "Ordner existiert nicht: $folder"; return
    }
    Set-Status "Lese Ordner..."
    $script:files = @(Get-ChildItem -Path $folder -Filter '*.mp3' -File | Sort-Object Name | Select-Object -ExpandProperty FullName)
    $lstFiles.BeginUpdate()
    $lstFiles.Items.Clear()
    foreach ($p in $script:files) {
        $marker = '[ ] '
        try {
            $tf = [TagLib.File]::Create($p)
            if ($tf.Tag.Pictures -and $tf.Tag.Pictures.Length -gt 0) { $marker = '[#] ' }
            $tf.Dispose()
        } catch {}
        [void]$lstFiles.Items.Add($marker + (Split-Path $p -Leaf))
    }
    $lstFiles.EndUpdate()
    Set-Status ("$($script:files.Count) MP3-Dateien geladen.  [#] = Cover vorhanden")
    if ($lstFiles.Items.Count -gt 0) { $lstFiles.SelectedIndex = 0 }
}

# --- Events --------------------------------------------------------------------
$lstFiles.Add_SelectedIndexChanged({
    if ($script:loading) { return }
    $i = $lstFiles.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:files.Count) {
        Load-File $script:files[$i]
    }
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path $txtFolder.Text) { $dlg.SelectedPath = $txtFolder.Text }
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtFolder.Text = $dlg.SelectedPath
        Load-Folder $dlg.SelectedPath
    }
})

$btnReload.Add_Click({ Load-Folder $txtFolder.Text })

$btnCover.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Bilder (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png|Alle Dateien (*.*)|*.*'
    if (Test-Path $txtFolder.Text) { $dlg.InitialDirectory = $txtFolder.Text }
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($dlg.FileName)
            $script:pendingCover = $bytes
            $script:removeCover  = $false
            if ($picCover.Image) { $picCover.Image.Dispose() }
            $picCover.Image = Load-ImageFromBytes $bytes
            Set-Status ("Cover gewählt (noch nicht gespeichert): " + (Split-Path $dlg.FileName -Leaf))
        } catch {
            Set-Status ("Bild konnte nicht geladen werden: " + $_.Exception.Message)
        }
    }
})

$btnCoverSearch.Add_Click({
    $artist = $txt['Artist'].Text.Trim()
    $title  = $txt['Title'].Text.Trim()
    if (-not $artist -and -not $title) {
        [System.Windows.Forms.MessageBox]::Show('Bitte erst Interpret/Titel ausfüllen (z.B. über "Aus Dateiname befüllen").',
            'Suche','OK','Information') | Out-Null
        return
    }
    Set-Status "Suche Cover für: $artist – $title ..."
    $form.Cursor = 'WaitCursor'
    try {
        $cands = Search-CoverCandidates $artist $title
    } finally {
        $form.Cursor = 'Default'
    }
    if (-not $cands -or $cands.Count -eq 0) {
        Set-Status 'Keine Cover gefunden (iTunes + MusicBrainz).'
        [System.Windows.Forms.MessageBox]::Show('Kein Cover gefunden. Tipp: Interpret/Titel vereinfachen (ohne Remix-Zusätze).',
            'Keine Treffer','OK','Information') | Out-Null
        return
    }
    Set-Status ("$($cands.Count) Treffer – bitte auswählen.")
    $bytes = Show-CoverPicker $cands
    if ($bytes) {
        $script:pendingCover = $bytes
        $script:removeCover  = $false
        if ($picCover.Image) { $picCover.Image.Dispose() }
        $picCover.Image = Load-ImageFromBytes $bytes
        Set-Status 'Online-Cover übernommen (noch nicht gespeichert – "Speichern" drücken).'
    } else {
        Set-Status 'Cover-Auswahl abgebrochen.'
    }
})

$btnCoverRemove.Add_Click({
    if ($picCover.Image) { $picCover.Image.Dispose(); $picCover.Image = $null }
    $script:pendingCover = $null
    $script:removeCover  = $true
    Set-Status 'Cover wird beim Speichern entfernt.'
})

$btnCoverAll.Add_Click({
    if (-not $script:pendingCover) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst ein Cover über "Cover wählen..." auswählen.',
            'Kein Cover','OK','Information') | Out-Null
        return
    }
    $targets = @()
    if ($lstFiles.SelectedIndices.Count -gt 1) {
        foreach ($idx in $lstFiles.SelectedIndices) { $targets += $script:files[$idx] }
    } else {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'Es ist nur eine Datei markiert. Cover auf ALLE Dateien im Ordner anwenden?',
            'Auf alle anwenden', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $targets = $script:files
    }
    $ok = 0; $fail = 0
    foreach ($p in $targets) {
        try {
            $tf  = [TagLib.File]::Create($p)
            $pic = New-Object TagLib.Picture (New-Object TagLib.ByteVector(,$script:pendingCover))
            $pic.Type = [TagLib.PictureType]::FrontCover
            $pic.Description = 'Cover'
            $tf.Tag.Pictures = @($pic)
            $tf.Save(); $tf.Dispose()
            Refresh-ListMarker $p
            $ok++
        } catch { $fail++ }
        Set-Status ("Cover anwenden... $ok ok / $fail Fehler")
    }
    Set-Status ("Cover auf $ok Datei(en) angewendet. Fehler: $fail")
})

$btnCleanTitles.Add_Click({ Invoke-TitleCleanup })

$btnCoverWizard.Add_Click({ Invoke-MissingCoverWizard })

$btnAutoName.Add_Click({
    if (-not $script:currentPath) { return }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($script:currentPath)
    $parsed = Parse-FileName $base
    if ($parsed.Artist) { $txt['Artist'].Text = $parsed.Artist }
    if ($parsed.Title)  { $txt['Title'].Text  = $parsed.Title }
    Set-Status 'Interpret/Titel aus Dateiname übernommen (noch nicht gespeichert).'
})

$btnSave.Add_Click({ [void](Save-Current) })

$btnSaveNext.Add_Click({
    if (Save-Current) {
        # Index der aktuell bearbeiteten Datei (robust bei Mehrfachauswahl)
        $i = [array]::IndexOf($script:files, $script:currentPath)
        if ($i -ge 0 -and $i -lt ($lstFiles.Items.Count - 1)) {
            $lstFiles.ClearSelected()           # Mehrfachauswahl aufheben, sonst bleiben beide markiert
            $lstFiles.SelectedIndex = $i + 1     # löst SelectedIndexChanged -> nächste Datei wird geladen
        } else {
            Set-Status 'Letzte Datei gespeichert.'
        }
    }
})

# Beim Start Ordner laden, falls vorhanden
$form.Add_Shown({
    if (Test-Path $txtFolder.Text) { Load-Folder $txtFolder.Text }
    $form.Activate()
})

[void]$form.ShowDialog()
$form.Dispose()
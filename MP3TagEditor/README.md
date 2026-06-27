# MP3 Tag & Cover Editor

Kleines WinForms-Tool (PowerShell 5.1) zum Stapel-Bearbeiten von ID3-Tags und Album-Covern,
ohne jede Datei in einem externen Programm einzeln anklicken zu müssen.

## Starten
Doppelklick auf **Start.cmd** (startet PowerShell mit STA + ExecutionPolicy Bypass).

## Funktionen
- **Dateiliste** des Ordners (Standard: `C:\Temp\MP3`), `[#]` = Cover bereits vorhanden, `[ ]` = kein Cover.
- **Tag-Felder**: Titel, Interpret, Album, Album-Interpret, Jahr, Genre, Track-Nr.
  (mehrere Interpreten/Genres mit `;` trennen).
- **Aus Dateiname befüllen**: parst `Interpret - Titel` und entfernt Zusätze wie `(Official Video)`,
  behält aber `(Remix)` / `(Radio Edit)`.
- **Cover wählen...**: Bild von der Festplatte einbetten.
- **Cover online suchen...**: holt Cover automatisch über die **iTunes Search API**
  (kein Account/Key nötig); findet iTunes nichts, wird **MusicBrainz / Cover Art Archive**
  als Fallback abgefragt. Treffer mit Vorschau zur Auswahl.
- **Titel von Zusätzen bereinigen...**: entfernt Stapel-weise aus dem **Titel-Tag** Klammer-Zusätze
  wie `(Official Music Video)`, `[TikTok Song]` usw. – mit Vorschau (Alt/Neu) und Häkchen pro Eintrag.
  Wirkt auf die in der Liste markierten Dateien (mehrere) bzw. sonst auf alle. **Dateinamen bleiben unverändert.**
- **Fehlende Cover durchgehen...**: Assistent, der **nur Dateien ohne Cover** der Reihe nach abarbeitet:
  zeigt die Datei, sucht automatisch online, du wählst ein Cover aus → wird gespeichert → weiter zur
  nächsten cover-losen Datei. Findet die Online-Suche nichts, kannst du ein Bild von der Platte wählen,
  überspringen oder den Assistenten beenden.
- **Cover entfernen**: löscht das eingebettete Bild beim Speichern.
- **Dieses Cover auf ALLE markierten anwenden**: mehrere Dateien in der Liste markieren
  (Strg/Shift) und ein Cover gleichzeitig setzen. Ist nur eine markiert, fragt das Tool,
  ob es auf den ganzen Ordner angewendet werden soll.
- **Speichern** / **Speichern + Weiter** (springt zur nächsten Datei – schneller Durchlauf).

## Wichtig
- Änderungen werden erst mit **Speichern** in die Datei geschrieben (Cover/Felder sind vorher nur Vorschau).
- `TagLibSharp.dll` muss im selben Ordner liegen (ist enthalten).
# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.

## [0.1.0.0] - 2026-06-27
### Erste Version
- WinForms-GUI (PowerShell 5.1) zum Stapel-Bearbeiten von ID3-Tags und Album-Covern.
- Tag-Felder: Titel, Interpret, Album, Album-Interpret, Jahr, Genre, Track-Nr.
- "Aus Dateiname befüllen": parst `Interpret - Titel` und entfernt Zusätze wie `(Official Video)`.
- "Cover wählen…": Bild von der Festplatte einbetten.
- "Cover online suchen…": iTunes Search API (primär) + MusicBrainz/Cover Art Archive (Fallback),
  Auswahl mit Vorschau.
- "Cover auf alle markierten anwenden": ein Cover auf mehrere Dateien gleichzeitig.
- "Titel von Zusätzen bereinigen…": Stapel-Bereinigung des Titel-Tags mit Vorschau (Häkchen pro Eintrag),
  Dateinamen bleiben unverändert.
- "Fehlende Cover durchgehen…": Assistent, der alle Dateien ohne Cover der Reihe nach abarbeitet
  (suchen → auswählen → speichern → weiter).
- "Speichern + Weiter" für schnellen Datei-für-Datei-Durchlauf.
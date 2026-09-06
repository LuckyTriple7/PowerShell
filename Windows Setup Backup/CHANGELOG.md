# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.

## [1.1.0.1] - 2026-09-06
### ZIP-Backups löschen
- Gültige ZIP-Backups können nach Sicherheitsprüfung direkt über die GUI gelöscht werden.
- Beim Löschen eines ZIP-Backups bleibt ein separat entpackter Backup-Ordner erhalten und umgekehrt.

## [1.1.0.0] - 2026-09-06
### Backup und Wiederherstellung erweitert
- Benutzerdefinierte Ordner mit Dateiendungsfiltern, Prüfsummen und kontrollierter Wiederherstellung ergänzt.
- Temporären Staging-Ablauf eingeführt: Nur fertige Archive oder abgeschlossene Ordner gelangen ins Sicherungsziel.
- ZIP-Backups werden in der GUI erkannt, direkt gelesen und vor der Wiederherstellung sicher entpackt.
- Optionale AES-256-geschützte 7z-Archive mit benutzergebunden geschützter Passwortablage ergänzt.
- WinGet-Pakete werden mit Version aufgelistet und können einzeln für die Wiederherstellung ausgewählt werden.
- Chocolatey-Inventar und selektive Wiederherstellung für UniGetUI-, Chocolatey-1.x- und Chocolatey-2.x-Installationen ergänzt.
- VS-Code-/VSCodium-Erweiterungen und PowerShellGet-Module werden inventarisiert und optional wiederhergestellt.
- Persistente Benutzer- und System-Umgebungsvariablen einschließlich additiver PATH-Wiederherstellung ergänzt.
- Optionale Windows-Features und Capabilities werden mit Administratorrechten inventarisiert und additiv wiederhergestellt.
- Netzwerkdrucker und persistente Netzlaufwerke werden wiederhergestellt; lokale Drucker bleiben dokumentiertes Inventar.
- Store-Apps werden über WinGet oder vorhandene Appx-Payloads behandelt und ansonsten als manuelle Installation gemeldet.
- Wiederherstellungs-GUI in Standard- und Zusatzbereiche aufgeteilt und sichtbare deutsche Umlaute korrigiert.

## [1.0.0.0] - 2026-09-05
### Erste Version
- Sicherung und Wiederherstellung von WinGet-Programmen, Python-/pip-Paketen, Startmenü-Verknüpfungen und ausgewählten Windows-Einstellungen.
- WinForms-GUI für Sicherung, Wiederherstellung, Vorschau, Löschung und Aufgabenplanung.

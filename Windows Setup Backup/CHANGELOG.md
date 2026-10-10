# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.

## [1.4.1.0] - 2026-10-10
### OpenCode-Desktop-App
- **Entwicklungsprogramme installieren** installiert zusätzlich die OpenCode-Desktop-App (`SST.OpenCodeDesktop`).

## [1.4.0.0] - 2026-10-10
### Entwicklungsumgebung auf neuem Rechner
- Neue Schaltfläche **Entwicklungsprogramme installieren** (Skript `Install-DevSetup.ps1`) installiert Git, GitHub CLI, Node.js, VS Code, 7-Zip und OpenCode auf einem frischen Windows.
- Mit Entwicklereinstellungen werden global installierte npm-Pakete gesichert und im Reiter Zusatzbereiche wiederhergestellt.
- Neue Schaltfläche **Entwicklungsumgebung wiederherstellen** spielt Einstellungen, VS-Code-Erweiterungen, npm-Pakete, SSH-Schlüssel und KI-Clients in einem Lauf zurück.
- Neues `Setup.cmd` installiert oder aktualisiert eine lokale Kopie unter `C:\Windows Setup Backup`, damit `GuiState` nicht über OneDrive zwischen Rechnern geteilt wird.
- GUI und Hintergrundaufträge starten auch bei der Standard-Ausführungsrichtlinie eines frischen Windows.

## [1.3.0.0] - 2026-10-01
### OpenCode und MCP-Server
- Die Option **KI-Clients** (bisher Claude-Code-Memories) sichert zusätzlich die OpenCode-Konfiguration aus `~\.config\opencode` (ohne `node_modules`, Lock- und `.bak`-Dateien).
- Benutzerweite Claude-Code-MCP-Server aus `~\.claude.json` werden gesichert und bei der Wiederherstellung in die vorhandene Datei zusammengeführt.
- Konfigurationen mit API-Schlüsseln (`opencode.json(c)`, MCP-Server) landen nur im verschlüsselten 7z mit sensiblen Daten.
- Fehlende Listen älterer Sicherungen werden nicht mehr als ein Eintrag gezählt.

## [1.2.1.0] - 2026-09-27
### Claude-Code-Daten
- Neue Option für Claude-Code-Memories und -Einstellungen (ohne Anmeldedaten und Verläufe) mit Wiederherstellung im Reiter Zusatzbereiche.

## [1.2.0.0] - 2026-09-27
### Sicherheit, Aufbewahrung und weitere Bereiche
- Das Archivpasswort muss in der GUI wiederholt werden; nur ein bestätigtes Passwort wird verwendet und gespeichert.
- Aufbewahrung: Nach erfolgreicher Sicherung werden ältere Sicherungen dieses Rechners bis auf die neuesten N gelöscht.
- Geplante Läufe melden Warnungen und Fehler als Windows-Benachrichtigung; der Zeitplan-Reiter warnt bei überfälliger Sicherung.
- Neue Aktion **Sicherung prüfen** vergleicht alle Dateien eines Backups mit den Prüfsummen im Manifest.
- Benutzerschriftarten, optional WLAN-Profile und SSH-Schlüssel (nur verschlüsseltes 7z) werden gesichert und wiederhergestellt; hosts, Energieplan und Standard-App-Zuordnungen liegen als Referenz bei.
- Umlaute in Meldungen des Hintergrundauftrags werden unter Windows PowerShell 5.1 korrekt angezeigt.

## [1.1.1.0] - 2026-09-06
### Stabilisierung von Backup und Restore
- Persistierte Aufträge werden typgeprüft; ältere Zeitpläne erhalten sichere Defaults für später ergänzte Optionen.
- Archive werden auch bei Vorschauen nur temporär entpackt und nicht durch gleichnamige Ordner ersetzt.
- Tatsächliche Restores erhalten vor Änderungen einen vollständigen WhatIf-Prüflauf; Warnungen beeinflussen Status und Exitcode.
- Schema-, Prüfsummen-, Reparse-Point-, Archivpfad- und Größenprüfungen wurden erweitert.
- Backups werden am Ziel zunächst unter einem temporären Namen validiert und erst danach veröffentlicht.
- Versionsdatei, CMD-Exitcode und mehrere Status- und Passwortzustände wurden korrigiert.
- Archivpasswörter mit Anführungszeichen werden vorab abgelehnt, da 7-Zip sie über die Kommandozeile nicht verarbeiten kann; ein Test prüft 7z-Backups mit Leerzeichen, Backslashes und Umlauten im Passwort.

## [1.1.0.4] - 2026-09-06
### Restore-Vorschau korrigiert
- Leere Paket- und Zusatzbereichsauswahlen werden als JSON-Arrays statt als leere Objekte gespeichert.
- Die Auftragsvalidierung ignoriert leere und alte fehlerhaft serialisierte Listenwerte.

## [1.1.0.3] - 2026-09-06
### 7z-Wiederherstellung korrigiert
- Passwortgeschützte 7z-Backups werden im Wiederherstellungsordner erkannt, gelesen und angezeigt.
- Ein separates, DPAPI-geschütztes Wiederherstellungspasswort und das automatische Entpacken vor der Wiederherstellung wurden ergänzt.
- Auswahl und Löschen unterstützen neben ZIP nun auch 7z-Archive.

## [1.1.0.2] - 2026-09-06
### Archivpasswort gespeichert
- Das Archivpasswort wird in den GUI-Einstellungen per Windows-DPAPI für den aktuellen Benutzer verschlüsselt gespeichert und beim nächsten Start wieder geladen.

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

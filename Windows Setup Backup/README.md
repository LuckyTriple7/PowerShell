# Windows-Setup sichern und wiederherstellen

Aktuelle Version: **1.1.0.0**. Änderungen sind in [`CHANGELOG.md`](CHANGELOG.md) dokumentiert.

PowerShell-Skripte für eine spätere Neuinstallation. Bilder, Dokumente und andere persönliche Dateien sind ausgeschlossen; diese kommen über OneDrive. Programme werden als Installationsliste erfasst, nicht als installierte Programmdateien gesichert. Ansible ist für die Skripte nicht erforderlich und kann sie später aufrufen.

## Sicherung erstellen

### Grafische Oberfläche

**`Start-GUI.cmd` doppelt anklicken.** Die GUI bietet vier Reiter:

- **Sicherung:** Zielordner auswählen, WinGet-, Chocolatey-, pip- und Entwicklereinstellungen festlegen, benutzerdefinierte Ordner ergänzen und Sicherung starten. Die Chocolatey-Checkbox ist nur aktiv, wenn `choco.exe` gefunden wurde. Zusätzliche Python-Interpreter und Ordner können zeilenweise eingetragen werden. Dateiendungen wie `tmp`, `.log` oder `cache` lassen sich für die benutzerdefinierten Ordner ausschließen.
- **Wiederherstellung:** Backup-Ordner, übergeordneten Ordner oder direkt ein ZIP-Backup auswählen. ZIP-Dateien im gewählten Quellordner werden automatisch erkannt; existiert der gleichnamige normale Backup-Ordner noch, wird er nicht doppelt angezeigt. Die gesicherten WinGet-Pakete werden mit Version aufgelistet und sind zunächst alle ausgewählt; nicht mehr benötigte Pakete können einzeln oder über **Keine auswählen** abgewählt werden. Bestandteile auswählen und zunächst **Vorschau (WhatIf)** verwenden. Für pip die gesicherte Umgebung und die gewünschte `python.exe` wählen. **Wiederherstellen** führt die ausgewählten Änderungen nach Bestätigung aus.
- **Zusatzbereiche:** Verwendet die im Reiter Wiederherstellung markierte Sicherung. Hier werden benutzerdefinierte Ordner, Chocolatey-Pakete, Store-Apps, Erweiterungen, Module, Umgebungsvariablen, Windows-Komponenten, Drucker und Netzlaufwerke separat ausgewählt, geprüft und gestartet.
- **Sicherung löschen:** In der Liste eine Sicherung markieren und **Sicherung löschen** wählen. Nach Bestätigung wird ausschließlich dieser Backup-Ordner dauerhaft entfernt, einschließlich eventuell enthaltener `BeforeRestore`-Dateien. Bei OneDrive wird die Löschung synchronisiert. Während einer Sicherung oder Wiederherstellung ist das Löschen gesperrt. Automatisch gelöscht werden nur erkannte Backups mit ihrem ursprünglichen Ordnernamen.
- **Zeitplan:** Tägliche oder wöchentliche Sicherung mit Uhrzeit und optionalem Akkubetrieb einrichten. **Zeitplan speichern** übernimmt die aktuellen Optionen aus dem Reiter Sicherung. Die Aufgabe lässt sich deaktivieren, aktivieren und entfernen; Backups bleiben erhalten.

Laufende Aktionen zeigen ihre Ausgabe im Fenster und melden den Abschluss. Die GUI wartet beim Schließen auf das Ende einer laufenden Aktion. Einstellungen, Aufträge und Protokolle liegen unter `GuiState` und sind von Git ausgeschlossen. Geplante Läufe protokollieren unter `GuiState\Runs`; Ergebniscode 0 bedeutet Erfolg, 2 bedeutet Abschluss mit Warnungen, 1 bedeutet Fehler.

Geplante Sicherungen laufen unter dem aktuellen Benutzer **nur bei angemeldetem Benutzer**, auch bei gesperrtem Bildschirm. Das Windows-Anmeldepasswort wird nicht gespeichert. Ein angegebenes Archivpasswort wird nicht in den GUI-Einstellungen gespeichert; Auftragsdateien enthalten es ausschließlich per Windows-DPAPI für den aktuellen Benutzer verschlüsselt. Für gemeinsames Startmenü oder bei fehlenden Rechten zur Aufgabenplanung die GUI als Administrator mit demselben Benutzer starten. Skriptordner und `GuiState` müssen am gespeicherten Ort lokal verfügbar bleiben; nach einem Verschieben den Zeitplan neu speichern. Eine Aufgabe wird erst durch den Klick auf **Zeitplan speichern** angelegt. Die GUI setzt keine Defender-Ausnahmen und ändert keine Ausführungsrichtlinien.

### Ohne GUI

Für den Start per Doppelklick **`Start-Backup.cmd`** verwenden. Das PowerShell-Fenster bleibt nach Abschluss oder einem Fehler offen. Ohne zusätzliche Parameter werden die Entwicklereinstellungen nicht mitgesichert.

Windows PowerShell 5.1 (64 Bit) als deinen normalen Benutzer öffnen:

```powershell
Set-Location 'C:\Users\andre\OneDrive\Dokumente\VSCode\Powershell\Windows Setup Backup'
.\Backup-WindowsSetup.ps1 -IncludeDeveloperSettings
```

Während der Sicherung erscheinen acht nummerierte Schritte mit Zeitstempeln, ein Fortschrittsbalken und beim Kopieren der aktuelle Dateiname. Der Gesamtbalken zeigt die abgeschlossenen Schritte, keine geschätzte Restzeit. Während des WinGet-Exports bleibt er beim laufenden Schritt stehen. Auch ohne sichtbaren Fortschrittsbalken bleiben die Statuszeilen lesbar.

Am Ende erscheint eine Übersicht mit Dauer, Anzahl der inventarisierten Programme, WinGet-Pakete, Dateien, Registry-Einstellungen und Warnungen. Sie wird zusätzlich als **`Zusammenfassung.txt`** gespeichert; **`backup.log`** enthält die laufenden Statusmeldungen. Fehler einzelner Exporte werden sofort und nochmals am Ende angezeigt. Bei einem fatalen Fehler erscheint „BACKUP ABGEBROCHEN“; ein solcher Ordner kann unvollständig sein. Die Abschlussmeldung bestätigt nicht die Vollständigkeit der WinGet-Zuordnung oder des OneDrive-Uploads.

Jeder Lauf erzeugt standardmäßig einen eigenen Ordner unter `C:\Users\andre\OneDrive\Backup\Windows\GigabyteA16\RECHNER-Zeitstempel`. Vor einer Neuinstallation prüfen, ob OneDrive die Sicherung vollständig hochgeladen hat. Konfigurationsdateien können Zugangsdaten oder interne Pfade enthalten; Sicherungsordner nicht veröffentlichen. Frühere Sicherungen unter `Backups` im Skriptordner bleiben dort erhalten und werden von Git ausgeschlossen.

Die GUI prüft beim Start, ob `7z.exe` über `PATH` oder in den üblichen 7-Zip-Installationsordnern vorhanden ist. Nur dann wird das optionale Passwortfeld angezeigt. Ohne 7-Zip kann weiterhin ein normales `.zip` ohne Passwort entstehen; mit 7-Zip und Passwort wird ein AES-256-verschlüsseltes `.7z` mit verschlüsselten Dateinamen erstellt. Bei aktivierter Archivoption wird ausschließlich das fertige Archiv in den Zielordner übertragen; ein paralleler ungepackter Backup-Ordner bleibt nicht zurück.

Der vollständige Sicherungslauf entsteht zunächst in einem eindeutigen Ordner unter `%TEMP%`. Erst nach Manifest, Zusammenfassung und erfolgreichem Packen wird das fertige Archiv ins eigentliche Sicherungsziel verschoben. Ohne Archivoption wird entsprechend der vollständig abgeschlossene Sicherungsordner verschoben. Temporäre Daten werden auch nach einem Fehler entfernt.

Von der Anwendung erzeugte ZIP-Backups können direkt oder über ihren übergeordneten Ordner ausgewählt werden. Vor der Wiederherstellung wird ein ZIP sicher in einen gleichnamigen Ordner neben dem Archiv entpackt; dieser Ordner bleibt für Wiederholungen und `BeforeRestore`-Sicherungen erhalten. Passwortgeschützte `.7z`-Archive müssen weiterhin zuerst mit 7-Zip entpackt werden.

Ein anderes Ziel lässt sich beim Aufruf angeben:

```powershell
.\Backup-WindowsSetup.ps1 -Destination 'D:\Backups\WindowsSetup'
```

Beim Aufruf über `powershell.exe -File` müssen Skriptpfad und Parameter getrennt bleiben. Für die CMD-Startdatei und native Aufrufe doppelte Anführungszeichen verwenden:

```powershell
powershell.exe -NoProfile -NoExit -File "C:\Users\andre\OneDrive\Dokumente\VSCode\Powershell\Windows Setup Backup\Backup-WindowsSetup.ps1" -Destination "C:\Users\andre\OneDrive\Backup\Windows\GigabyteA16"
```

`-Destination` gehört außerhalb der Anführungszeichen um den Skriptpfad. Für das voreingestellte Ziel reicht ein Doppelklick auf `Start-Backup.cmd` ohne Parameter.

Falls WinGet erstmalig die Zustimmung zu Paketquellen benötigt, steht das im Export-Log. Die folgende Variante akzeptiert deren Bedingungen ausdrücklich:

```powershell
.\Backup-WindowsSetup.ps1 -IncludeDeveloperSettings -AcceptSourceAgreements
```

Optional: `-Destination 'E:\WindowsSetup'` für ein anderes Sicherungsziel oder `-SkipWinget` für eine Sicherung ohne WinGet-Aufruf. Der Sicherungslauf verändert keine Windows-Einstellungen und installiert keine Programme. WinGet kann seine Quellen und Caches aktualisieren.

## Inhalt

| Datei/Bereich | Inhalt und Grenzen |
|---|---|
| `installed-programs.csv` / `.json` | Inventar aus den 32-/64-Bit-Uninstall-Schlüsseln für Rechner und aktuellen Benutzer. Kein `Win32_Product`, keine MSI-Reparaturläufe. Portable Programme und andere Benutzerprofile werden nicht vollständig erfasst. |
| `store-apps.json` | Appx-/Store-Inventar des aktuellen Benutzers; reine Referenz, keine automatische Wiederherstellung aus dieser Datei. |
| `winget-packages.json` | Von WinGet zugeordnete Pakete einschließlich Versionsnummern; Grundlage der Neuinstallation. |
| `winget-export.log` | Unbedingt auf nicht zugeordnete Programme und Fehler prüfen. Ein erfolgreicher Export bedeutet nicht, dass alle Programme enthalten sind. Fehlende Programme benötigen eigene Installer. |
| `Files\StartMenu*` | `.lnk`- und `.url`-Verknüpfungen mit Ordnerstruktur aus persönlichem und gemeinsamem Startmenü. Keine installierten Anwendungen. |
| `start-layout.json` | Angeheftetes Startlayout unter Windows 11, soweit der Export gelingt; Windows 10 verwendet XML. Referenz für eine manuelle oder später versionsgerecht implementierte Wiederherstellung. |
| `settings-registry.json` | Vorhandene DWORD-Werte für Dateiendungen, versteckte/Systemdateien, Explorer-Startansicht, Taskleistenausrichtung, Taskansicht-Schaltfläche, helles/dunkles App-/Systemdesign und Transparenz. |
| Optionale Entwicklereinstellungen | Mit `-IncludeDeveloperSettings`: PowerShell-Profildateien, `.gitconfig`, `.gitignore_global`, VS-Code-Einstellungen/Tastenkürzel/Snippets und Windows-Terminal-Einstellungen (Stable/ungepackt). Keine Module, VS-Code-Erweiterungen oder kompletten AppData-Verzeichnisse. |
| Benutzerdefinierte Ordner | Mit `-CustomFolders` rekursiv unter `Files\CustomFolders`. `-ExcludedExtensions tmp,log` schließt diese Dateiendungen nur dort aus. Ursprünglicher Pfad, Ablagepfad, Anzahl und Datei-Prüfsummen stehen im Manifest. Bei der Wiederherstellung werden die Ordner einzeln ausgewählt. |
| `developer-packages.json` | Mit Entwicklereinstellungen: installierte VS-Code-/VSCodium-Erweiterungen und über PowerShellGet bekannte Module. Manuell kopierte Module und Remote-/Container-Erweiterungen sind nicht enthalten. |
| `package-managers.json` | Lokal installierte Chocolatey-Pakete mit Version. Unterstützt Chocolatey 1.x (`list --local-only`) und 2.x (`list`). Typische Erweiterungs- und Implementierungspakete bleiben sichtbar, sind in der GUI aber standardmäßig abgewählt. |
| `environment-variables.json` | Persistente Benutzer- und Systemvariablen einschließlich nicht expandierter Werte und Registry-Typ. Namen mit Hinweisen auf Passwort, Token, Secret oder API-Key werden markiert und ohne Wert gespeichert. |
| `windows-components.json` | Aktivierte optionale Windows-Features und installierte Capabilities. Das vollständige Inventar erfordert eine als Administrator gestartete Sicherung. |
| `devices-connections.json` | Druckerinventar und persistente Netzlaufwerke. Automatisch wiederherstellbar sind Netzwerkdrucker und Netzlaufwerke; lokale/WSD-/USB-Drucker bleiben wegen fehlender Treiberpakete Inventar. |
| `manifest.json` | Windows-Version, ursprünglicher Profilpfad, Dateiliste mit SHA256-Prüfsummen, Exportstatus und Warnungen. Wird erst am Ende des Laufs geschrieben. |

Anwendungseinstellungen weiterer Programme müssen gezielt ergänzt werden. Lizenzaktivierungen, gespeicherte Anmeldungen, komplette Browserprofile, Treiber, laufende Programmzustände und angeheftete Taskleisten-Apps sind nicht enthalten.

## Wiederherstellen

Windows und WinGet müssen bereits eingerichtet sein. OneDrive-Sicherungsordner vollständig herunterladen, Anwendungen installieren und betroffene Anwendungen vor dem Zurückspielen ihrer Einstellungen schließen. Mit dem gewünschten Zielbenutzer arbeiten; `HKCU` und Profilpfade beziehen sich immer auf diesen Benutzer.

Den tatsächlichen Sicherungsordner einsetzen:

```powershell
$backup = '.\Backups\DEIN-PC-ZEITSTEMPEL'

# Vorschau: validiert Dateien und zeigt geplante Änderungen, ohne zu schreiben.
.\Restore-WindowsSetup.ps1 -BackupPath $backup -Programs -Settings -Shortcuts -WhatIf

# Programme installieren; akzeptiert Paket- und Quellenbedingungen ausdrücklich.
.\Restore-WindowsSetup.ps1 -BackupPath $backup -Programs -AcceptAgreements

# Einstellungen und persönliche Startmenü-Verknüpfungen zurückspielen.
.\Restore-WindowsSetup.ps1 -BackupPath $backup -Settings -Shortcuts
```

Die Wiederherstellung validiert zuerst alle ausgewählten Sicherungsdateien. Danach installiert WinGet die ausgewählten Programme; erst anschließend werden Startmenü-Verknüpfungen, Entwicklerkonfigurationen und Registry-Einstellungen zurückgespielt. Das exportierte angeheftete Startlayout wird nicht automatisch importiert, sondern bleibt eine manuelle Referenz. Damit werden Verknüpfungen erst nach den Programmen angelegt, deren Ziele sie verwenden.

Zusätzliche Bereiche sind in der GUI separat wählbar. Benutzerdefinierte Ordner werden einzeln mit ihrem gespeicherten Originalpfad angezeigt; vorhandene abweichende Dateien werden vor dem Überschreiben unter `BeforeRestore-Custom-*` gesichert. Umgebungsvariablen werden additiv behandelt: fehlende Werte werden ergänzt, vorhandene Werte nicht überschrieben und `Path` wird ohne Löschen vorhandener Einträge zusammengeführt. Systemvariablen und Windows-Komponenten benötigen Administratorrechte. Features und Capabilities werden nur ergänzt, niemals deaktiviert.

VS-Code-Erweiterungen werden über die jeweilige installierte CLI und PowerShell-Module aus `PSGallery` in `CurrentUser` installiert. Netzwerkdrucker und Netzlaufwerke werden nur ergänzt; belegte Laufwerksbuchstaben werden nicht ersetzt. Lokale Drucker bleiben Inventar, weil Treiber, Ports und Herstellersoftware nicht portabel im Backup enthalten sind.

Chocolatey wird über `PATH`, `%ChocolateyInstall%`, die lokale UniGetUI-Installation und `%ProgramData%\chocolatey` gesucht. Die Checkbox **Chocolatey-Pakete** aktiviert die darunterliegende Paketliste; Pakete werden anschließend einzeln ausgewählt und mit `choco install` installiert. Die Option für gespeicherte Versionen gilt auch hier. Mögliche Namensüberschneidungen mit dem WinGet-Inventar werden vor der Installation gemeldet. Chocolatey-Abhängigkeiten werden weiterhin durch Chocolatey selbst aufgelöst. Viele systemweite Pakete benötigen eine als Administrator gestartete GUI.

Store-Apps, die WinGet beim Export eindeutig der Quelle `msstore` zuordnen konnte, sind bereits Teil der normalen WinGet-Paketliste. Für zusätzlich ausgewählte Appx-Einträge versucht die GUI nur die Registrierung eines auf dem Zielsystem vorhandenen Windows-Payloads. Fehlende, kostenpflichtige, entfernte oder nicht eindeutig identifizierbare Apps werden als manuelle Store-Installation gemeldet; aus einem `PackageFamilyName` wird keine unsichere WinGet-ID geraten.

Standardmäßig verwendet WinGet aktuelle verfügbare Versionen und überspringt bereits installierte Programme (`--no-upgrade`). Mit `-UseSavedVersions` werden stattdessen die gespeicherten Versionen angefordert; alte Installer können fehlen. Die GUI übergibt die angehakten Paket-IDs an `-PackageIds`; ohne diesen Parameter verarbeitet der direkte Skriptaufruf weiterhin alle gesicherten Pakete. Nicht verfügbare Pakete werden nicht stillschweigend ignoriert. Bei einem WinGet-Fehler bricht das Skript ab; bereits erfolgte Installationen werden nicht rückgängig gemacht. `-WhatIf` listet die gewählten Pakete auf, prüft aber nicht ihre Online-Verfügbarkeit.

Für gemeinsame Verknüpfungen PowerShell als Administrator **mit demselben Benutzerkonto** öffnen:

```powershell
.\Restore-WindowsSetup.ps1 -BackupPath $backup -Shortcuts -IncludeCommonStartMenu
```

Geänderte vorhandene Dateien werden vor dem Überschreiben im Sicherungsordner unter `BeforeRestore-Zeitstempel` aufgehoben. Vor Registry-Änderungen werden die vorhandenen unterstützten Werte und die angeforderten Werte dort protokolliert. Das ist eine Hilfe zur manuellen Rücksicherung, kein automatisches Rollback; neu angelegte Dateien/Werte müssten bei Bedarf manuell entfernt werden. Identische Dateien und Werte werden übersprungen. Zusätzliche bestehende Dateien werden nicht gelöscht.

Absolute Pfade in Verknüpfungen, Git-Includes, PowerShell-Profilen und Terminal-Konfigurationen werden nicht umgeschrieben. Bei anderem Benutzernamen oder Installationspfad können Anpassungen notwendig sein. PowerShell-Profile sind ausführbarer Code: nur eigene, vertrauenswürdige Sicherungen verwenden.

## Python und pip

Neue Backups enthalten standardmäßig zusätzlich **`Python\environments.json`** und je erkanntem Interpreter eine eigene **`requirements.txt`**, **`packages.json`** und Fehlerlogs. Erkannt werden echte `python.exe`-/`python3.exe`-Einträge im PATH und die üblichen Installationen unter `%LOCALAPPDATA%\Programs\Python`. Store-Ausführungsaliase werden ausgelassen. Die Python-Version und der ursprüngliche Interpreterpfad werden mitgesichert. `pip freeze --all` erfasst auch Abhängigkeiten und pip selbst. Alle Aufrufe erfolgen über den jeweiligen Interpreter mit `-m pip`; sie installieren beim Backup nichts.

Das gilt unabhängig von `-IncludeDeveloperSettings`. Mit `-SkipPython` lässt sich der Schritt ausschalten. Bereits vorhandene Backups werden nicht nachträglich geändert: für pip ein neues Backup erstellen.

Weitere Interpreter, insbesondere Projektumgebungen, explizit ergänzen:

```powershell
.\Backup-WindowsSetup.ps1 -PythonExecutables 'C:\Projekte\MeinProjekt\.venv\Scripts\python.exe'
```

Es erfolgt keine Suche über die gesamte Festplatte. Conda-Umgebungen, weitere Benutzer, pipx und `uv tool` werden nicht gesondert inventarisiert. Ein über uv bereitgestellter Interpreter im PATH wird geprüft; fehlt ihm pip, wird das als unvollständiger Export mit Warnung vermerkt. Zusätzliche Systemabhängigkeiten wie Playwright-Browser, Compiler oder DLLs sind nicht Teil der pip-Liste. Lokale/editierbare Pakete benötigen weiterhin ihre Quellordner. Paketquellen, Zugangsdaten und `pip.ini` werden nicht separat gesichert; direkte URLs in `requirements.txt` können dennoch sensible Informationen enthalten.

Die Umgebungen werden bewusst einzeln in einen von dir angegebenen Interpreter zurückgespielt. Python samt pip vorher installieren; die Python-Haupt-/Nebenversion muss passen, zum Beispiel 3.14. Ziel und Umgebungs-ID anhand von `Python\environments.json` wählen:

```powershell
.\Restore-PythonPackages.ps1 -BackupPath $backup -EnvironmentId python-01 -PythonExecutable 'C:\Pfad\zu\Python314\python.exe' -WhatIf

# Nach Prüfung denselben Aufruf ohne -WhatIf ausführen.
```

Die Wiederherstellung installiert die gespeicherten Paketversionen und kann vorhandene Versionen ändern. Es gibt kein automatisches Rollback. Die Vorschau kontrolliert die Sicherungsdatei und zeigt das Ziel; Interpreterversion und Paketverfügbarkeit werden erst beim tatsächlichen Lauf geprüft. Ein Freeze-Export ist eine Bestandsaufnahme, kein vollständiges Lockfile oder Offline-Archiv. Die Pakete müssen später noch verfügbar und mit dem Zielsystem kompatibel sein. `Restore-WindowsSetup.ps1 -Programs` installiert weiterhin nur WinGet-Pakete; für pip das separate Skript verwenden.

## Startmenü unter Windows 11 Home

Der hier erkannte Rechner verwendet Windows 11 Home 25H2 (Build 26200). Die Skripte sichern normale Verknüpfungen und versuchen den offiziellen Layout-Export. Sie importieren die angehefteten Apps nicht automatisch. Die von Microsoft dokumentierte Bereitstellung des Layouts hängt von Edition, Build und Richtlinienunterstützung ab; ein universeller Import für dieses Home-System wird hier nicht vorausgesetzt. Pins nach der Installation anhand der exportierten JSON-Datei manuell setzen. Eine Kopie interner `start*.bin`-Datenbanken wird nicht als verlässliches Wiederherstellungsverfahren verwendet.

## Später mit Ansible

Die Skripte können über `ansible.windows.win_powershell` bzw. `win_shell` gestartet werden. Zuerst mit dem normalen Windows-Benutzer lokal testen: WinGet, Startlayout und Benutzerkonfigurationen hängen vom Benutzerprofil ab und können in einer Remoting-Sitzung anders funktionieren. Die Skripte richten weder WinRM noch Ansible ein. Sie sind für einmalige Sicherung/Wiederherstellung gedacht und melden keinen Ansible-Änderungsstatus für jeden einzelnen Schritt.

## Quellen

- [Microsoft: WinGet export](https://learn.microsoft.com/en-us/windows/package-manager/winget/export)
- [pip: freeze](https://pip.pypa.io/en/stable/cli/pip_freeze/)
- [pip: list](https://pip.pypa.io/en/stable/cli/pip_list/)
- [Microsoft: WinGet import](https://learn.microsoft.com/en-us/windows/package-manager/winget/import)
- [Microsoft: Startlayout exportieren und bereitstellen](https://learn.microsoft.com/en-us/windows/configuration/start/layout)
- [Ansible: Windows verwalten und Besonderheiten von Remoting](https://docs.ansible.com/projects/ansible/latest/os_guide/intro_windows.html)

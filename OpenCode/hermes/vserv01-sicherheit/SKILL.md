---
name: vserv01-sicherheit
description: Ausführlicher Sicherheits-Check des Servers vserv01 – CrowdSec (Sperren, Alerts, Bouncer), TLS-Zertifikate (Short-Lived, ~6,7 Tage) von NPMplus und Mailcow, Backups. Nutzen bei Fragen nach Angriffen, Zertifikaten oder Backups.
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [vserv01, monitoring, sicherheit, crowdsec, backup]
    category: devops
---

# vserv01: Sicherheit

Nur Live-Daten, nichts erfinden, keine Websuche, Deutsch. Genau diese 3 Werkzeugaufrufe, keine weiteren und keine Wiederholungen:

1. monitor crowdsec_status mit limit=15
2. monitor maintenance_status mit section="certs"
3. monitor maintenance_status mit section="backups"

Verboten: alle uptime_kuma-Werkzeuge. Liefert ein Aufruf einen Fehler, schreibe für diesen Abschnitt "nicht verfügbar" und mache weiter.

Die Zertifikate sind Short-Lived (Laufzeit ~6,7 Tage). 3 bis 6 Tage Restlaufzeit sind normal, nicht als Problem darstellen. Alarm nur, wenn das Werkzeug ein [!] meldet.

Gib die Antwort GENAU EINMAL aus, ohne Text davor oder danach, mit je einer Leerzeile zwischen den Abschnitten:

🛡️ **vserv01 – Sicherheit**

🚫 **CrowdSec**
Sperren: <lokal erkannt> lokal, Blocklisten <Zahlen>
Alerts 24 h: <Anzahl>, Szenarien: <Top 5>, Länder: <Top 5>
Letzte Sperren: <bis zu 8 Zeilen "IP (Land, AS) – Szenario">
Bouncer/Maschinen: <ok oder Warnungen>; Hub: <aktuell oder Einträge mit Update>

🔐 **Zertifikate**
<je Zertifikat eine Zeile: Domain – noch X Tage; Warnungen fett mit ⚠️; nicht ausgelieferte Dateien nur als eine Zeile am Ende>

💾 **Backups**
<je Backup eine Zeile: Name – vor X h, Ergebnis; Warnungen mit ⚠️>

✅ **To-do**
<nur Befehle aus den Werkzeug-Antworten, als root auf vserv01; sonst "nichts zu tun">

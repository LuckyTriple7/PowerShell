---
name: vserv01-updates
description: Ausführlicher Update-Check des Servers vserv01 – Debian-Pakete (Sicherheitsupdates), Docker-Images inkl. neuerer Versions-Tags und Hauptversionen, LiteLLM-Version. Nutzen bei Fragen nach Updates auf vserv01.
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [vserv01, monitoring, updates]
    category: devops
    requires_toolsets: [terminal]
---

# vserv01: Updates

Nur Live-Daten, nichts erfinden, keine Websuche, Deutsch. Genau diese Aufrufe:

1. monitor apt_updates
2. monitor image_updates mit check_new_versions=true
   Antwortet es mit "Prüfung läuft noch", im Terminal `sleep 60` ausführen und image_updates mit denselben Parametern GENAU EINMAL erneut aufrufen. Läuft es dann immer noch, den Abschnitt "Prüfung läuft noch, später erneut fragen" nennen.
3. Terminal: `python3 /config/.hermes/scripts/litellm_update.py --always`

Verboten: alle uptime_kuma-Werkzeuge, weitere Aufrufe. Liefert ein Aufruf einen Fehler, schreibe für diesen Abschnitt "nicht verfügbar" und mache weiter.

Gib die Antwort GENAU EINMAL aus, ohne Text davor oder danach, mit je einer Leerzeile zwischen den Abschnitten:

🔄 **vserv01 – Updates**

📦 **Debian**
<Anzahl Updates, davon Sicherheitsupdates; Sicherheitsupdates einzeln mit alter → neuer Version, übrige nur als Anzahl; Neustart nötig ja/nein>

🐳 **Docker-Images**
<"Neues Image (pull nötig)", "neueres Image gepullt, Container alt", "neuere Version (Tag ändern)", "neue Hauptversion" je mit Image → Ziel; sonst "alle aktuell". Lokal gebaute Images weglassen>

🤖 **LiteLLM**
<Ausgabe des Skripts unverändert>

✅ **To-do**
<nur Befehle aus den Werkzeug-Antworten, als root auf vserv01. Bei neuer Hauptversion: "Changelog lesen, vor allem bei Datenbanken". Sonst "nichts zu tun">

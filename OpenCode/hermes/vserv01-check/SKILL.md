---
name: vserv01-check
description: Kompletter, ausführlicher Check des Servers vserv01 mit Ampel je Bereich (System, Dienste, Updates, Sicherheit, Zertifikate, Backups, Docker-Speicher) und To-do-Liste. Für Details je Bereich gibt es vserv01-ressourcen, vserv01-updates und vserv01-sicherheit.
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [vserv01, monitoring, check]
    category: devops
    requires_toolsets: [terminal]
---

# vserv01: Kompletter Check

Nur Live-Daten, nichts erfinden, keine Websuche, Deutsch. Genau diese 7 Aufrufe, keine weiteren und keine Wiederholungen:

1. monitor health_check
2. monitor server_overview
3. monitor failed_services
4. monitor apt_updates mit security_only=true
5. monitor crowdsec_status mit limit=5
6. monitor maintenance_status mit section="all"
7. Terminal: `python3 /config/.hermes/scripts/litellm_update.py --always`

Verboten: alle uptime_kuma-Werkzeuge und image_updates (dauert zu lange; der Image-Stand steht in health_check). Liefert ein Aufruf einen Fehler, schreibe für diesen Bereich "nicht verfügbar" und mache weiter.

Ampel je Bereich: 🟢 keine Warnung, 🟡 Hinweis/Update verfügbar, 🔴 Warnung mit [!] (Ausfall, Fehler, Sicherheitsupdate, Zertifikat/Backup-Warnung). Zertifikate sind Short-Lived (~6,7 Tage), 3 bis 6 Tage Rest sind grün.

Gib die Antwort GENAU EINMAL aus, ohne Text davor oder danach, mit je einer Leerzeile zwischen den Abschnitten:

🩺 **vserv01 – Komplett-Check <TT.MM. HH:MM>**

<Ampel> **System** – CPU <x> %, RAM <x> %, Swap <x> %, Platten <höchster Wert> %, Neustart nötig <ja/nein>
<Ampel> **Dienste** – <fehlgeschlagene Dienste/Container oder "alle laufen">
<Ampel> **Updates** – Debian <n> (<s> Sicherheit), Images <aus health_check>, LiteLLM <aktuell / neue Version>
<Ampel> **CrowdSec** – <Sperren>, <Alerts 24 h>, Bouncer <ok/Problem>
<Ampel> **Zertifikate** – <alle gültig, kürzeste Restlaufzeit X Tage / Warnung>
<Ampel> **Backups** – <n ok / Warnungen>
<Ampel> **Docker-Speicher** – <freigebbar X / Warnung>

⚠️ **Auffälligkeiten**
<jede Warnung aus den Werkzeugen eine Zeile; sonst "keine">

✅ **To-do**
<nummerierte Liste, nur Befehle aus den Werkzeug-Antworten, als root auf vserv01; sonst "nichts zu tun">

Für Details: /vserv01_ressourcen, /vserv01_updates, /vserv01_sicherheit

---
name: vserv01-check
description: Kompletter, ausführlicher Check des Servers vserv01 mit Ampel je Bereich (System, Dienste, Updates, LiteLLM, CrowdSec, Zertifikate, Backups, Docker-Speicher) und To-do-Liste.
version: 2.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [vserv01, monitoring]
    category: devops
---

# vserv01-check

Der Bericht kommt fertig formatiert vom Server.

1. Genau EINEN Werkzeugaufruf machen: monitor report mit section="check"
   (Toolname: mcp__monitor__monitor_mcp_report)
2. Das Ergebnis UNVERÄNDERT als Antwort ausgeben. Nichts weglassen, nichts umformulieren, nichts ergänzen, kein Text davor oder danach.

Keine weiteren Werkzeuge, keine Websuche, kein Terminal. Liefert der Aufruf einen Fehler, nur die Fehlermeldung ausgeben.

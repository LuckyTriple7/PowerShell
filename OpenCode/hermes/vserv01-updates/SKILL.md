---
name: vserv01-updates
description: Update-Check des Servers vserv01 – Debian-Pakete, Docker-Images inkl. neuerer Versionen, LiteLLM-Version, fertige Update-Befehle.
version: 2.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [vserv01, monitoring]
    category: devops
---

# vserv01-updates

Der Bericht kommt fertig formatiert vom Server.

1. Genau EINEN Werkzeugaufruf machen: monitor report mit section="updates"
   (Toolname: mcp__monitor__monitor_mcp_report)
2. Das Ergebnis UNVERÄNDERT als Antwort ausgeben. Nichts weglassen, nichts umformulieren, nichts ergänzen, kein Text davor oder danach.

Keine weiteren Werkzeuge, keine Websuche, kein Terminal. Liefert der Aufruf einen Fehler, nur die Fehlermeldung ausgeben.

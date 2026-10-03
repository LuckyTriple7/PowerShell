---
name: litellm-kosten
description: Kosten in LiteLLM – heute, gestern, laufender Monat, je Key mit Budget und die teuersten Modelle.
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [litellm, kosten, budget]
    category: devops
---

# litellm-kosten

Der Bericht kommt fertig formatiert vom Server.

1. Genau EINEN Werkzeugaufruf machen: monitor report mit section="kosten"
   (Toolname: mcp__monitor__monitor_mcp_report)
2. Das Ergebnis UNVERÄNDERT als Antwort ausgeben. Nichts weglassen, nichts umformulieren, nichts ergänzen, kein Text davor oder danach.

Keine weiteren Werkzeuge, keine Websuche, kein Terminal. Liefert der Aufruf einen Fehler, nur die Fehlermeldung ausgeben.

---
name: mcp-freigaben
description: Zeigt, welche MCP-Server der Hermes-Key in LiteLLM nutzen darf und ob alle Tools des Monitor-MCP eingeschaltet und freigegeben sind (nur lesend).
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [litellm, mcp, freigaben]
    category: devops
---

# mcp-freigaben

Der Bericht kommt fertig formatiert vom Server.

1. Genau EINEN Werkzeugaufruf machen: monitor report mit section="freigaben"
   (Toolname: mcp__monitor__monitor_mcp_report)
2. Das Ergebnis UNVERÄNDERT als Antwort ausgeben. Nichts weglassen, nichts umformulieren, nichts ergänzen, kein Text davor oder danach.

Keine weiteren Werkzeuge, keine Websuche, kein Terminal. Liefert der Aufruf einen Fehler, nur die Fehlermeldung ausgeben.

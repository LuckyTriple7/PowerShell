---
name: vserv01
description: Sammel-Einstieg für alle vserv01-Berichte. Fragt per Menü, was der Nutzer wissen möchte (Check, Ressourcen, Updates, Sicherheit, Kosten, MCP-Freigaben, LiteLLM-Release-Notes), und liefert dann genau diesen Bericht.
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [vserv01, monitoring, litellm, menue]
    category: devops
---

# vserv01

Ein Befehl für alle vserv01-Berichte. Die einzelnen Skills (vserv01-check, vserv01-ressourcen,
vserv01-updates, vserv01-sicherheit, litellm-kosten, mcp-freigaben, litellm-update) bleiben bestehen.

## Schritt 1: Auswahl klären

Steht hinter dem Aufruf schon eine Auswahl (Nummer oder Stichwort, z. B. `/vserv01 3` oder
`/vserv01 updates`), direkt mit Schritt 2 weitermachen.

Sonst KEIN Werkzeug aufrufen und genau dieses Menü ausgeben, danach auf die Antwort warten:

```
Was möchtest du zu vserv01 wissen?
1 – Kompletter Check (alles mit Ampel und To-do)
2 – Ressourcen (CPU, RAM, Platten, Dienste)
3 – Updates (Pakete, Docker-Images, LiteLLM)
4 – Sicherheit (CrowdSec, Zertifikate, Backups)
5 – Kosten (LiteLLM, je Key und Modell)
6 – MCP-Freigaben (Hermes-Key)
7 – LiteLLM-Release-Notes (neue Version?)
Antworte mit Nummer oder Stichwort.
```

## Schritt 2: Bericht holen

| Auswahl | Stichworte | section |
|---|---|---|
| 1 | check, alles, komplett, status | check |
| 2 | ressourcen, cpu, ram, speicher, platte | ressourcen |
| 3 | updates, pakete, images | updates |
| 4 | sicherheit, crowdsec, zertifikate, backup | sicherheit |
| 5 | kosten, budget, geld | kosten |
| 6 | freigaben, mcp, rechte | freigaben |
| 7 | release, notes, litellm-version | (siehe unten) |

Für 1 bis 6:
1. Genau EINEN Werkzeugaufruf machen: monitor report mit der section aus der Tabelle
   (Toolname: mcp__monitor__monitor_mcp_report)
2. Das Ergebnis UNVERÄNDERT als Antwort ausgeben. Nichts weglassen, nichts umformulieren,
   nichts ergänzen, kein Text davor oder danach.

Für 7:
1. Genau einmal im Terminal ausführen: `python3 /config/.hermes/scripts/litellm_update.py --notes`
2. Die Zeilen bis vor `--- Release Notes` unverändert ausgeben.
3. Gibt es Release Notes, darunter höchstens 6 Stichpunkte auf Deutsch: zuerst Breaking Changes,
   DB-Migrationen und Sicherheitsfixes, dann wichtige neue Funktionen. Nichts erfinden.
   Steht dort „(gekürzt)“, auf den Link verweisen.
4. Kein Update selbst ausführen (das macht der Nutzer als root mit `update-litellm`).

## Regeln

- Passt die Antwort zu keiner Zeile, das Menü noch einmal ausgeben, nichts raten.
- Pro Auswahl nur der eine Aufruf aus Schritt 2. Keine Websuche, keine weiteren Werkzeuge.
- Liefert der Aufruf einen Fehler, nur die Fehlermeldung ausgeben.
- Nennt der Nutzer danach eine weitere Nummer, wieder Schritt 2 für diese Auswahl.

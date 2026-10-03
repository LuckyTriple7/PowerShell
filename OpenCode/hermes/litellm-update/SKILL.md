---
name: litellm-update
description: Prüft, ob es für LiteLLM auf vserv01 eine neuere stabile Version gibt (Version ist gepinnt), und fasst auf Wunsch die Release Notes zusammen. Nutzen bei Fragen nach LiteLLM-Updates oder -Version.
version: 1.0.0
author: LuckyTriple7 + Claude
metadata:
  hermes:
    tags: [litellm, vserv01, update]
    category: devops
    requires_toolsets: [terminal]
---

# LiteLLM-Update prüfen

LiteLLM läuft auf vserv01 mit fest eingetragener Version (`ghcr.io/berriai/litellm:vX.Y.Z`).
Das Skript vergleicht die laufende Version mit der neuesten stabilen Version auf GitHub.

## Ablauf

1. Genau einmal im Terminal ausführen:
   `python3 /config/.hermes/scripts/litellm_update.py --notes`
2. Die Zeilen bis vor `--- Release Notes` unverändert ausgeben.
3. Gibt es Release Notes, darunter höchstens 6 Stichpunkte auf Deutsch:
   zuerst Breaking Changes, DB-Migrationen und Sicherheitsfixes, dann wichtige neue Funktionen.
   Nichts erfinden, was nicht in den Notes steht. Steht dort „(gekürzt)“, auf den Link verweisen.
4. Ist LiteLLM aktuell oder schlägt die Prüfung fehl: nur die Skriptausgabe, keine weiteren Aufrufe.

## Regeln

- Kein Update selbst ausführen. Das Update macht der Nutzer als root auf vserv01
  mit `update-litellm -n` (Probelauf) und `update-litellm`.
- Keine Websuche, kein Browser. Die Daten kommen nur aus dem Skript.
- Kurz antworten, Deutsch.

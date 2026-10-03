# Backlog – LiteLLM & MCPs

Stack: `vserv01:/opt/docker/stacks/litellm-caveman` (compose.yml + compose.video-mcp.yml)

## Offen

### Stack-Ordner mit Git versionieren
- Git-Repo in `/opt/docker/stacks/litellm-caveman` anlegen, statt bei jeder Änderung `.bak-*`-Dateien zu erzeugen.
- In `.gitignore`: `.env`, `.env.*`, `*.bak-*`, `backups/`, `*.mp4`, `__pycache__/`
- Commit nach jeder Änderung; Rollback per `git checkout -- <datei>`.

### fal-Kosten nativ über LiteLLM (sobald v1.104.0 stabil ist)
- LiteLLM bekommt die Route `/fal_ai/{endpoint}` (PR [#42360](https://github.com/BerriAI/litellm/pull/42360), bisher nur in `v1.104.0-dev.1`, Stand 03.10.2026): leitet an `queue.fal.run` weiter, nimmt den virtuellen LiteLLM-Key und bucht die Kosten beim Absenden in die Spend-Logs.
- Haken: Die Route nimmt nur Endpunkte mit Eintrag in der LiteLLM-Preistabelle an (sonst 400). Am 03.10.2026 standen dort für fal-Video nur Seedance 2.0/2.5 und MiniMax H3, **nicht** unsere Endpunkte `fal-ai/kling-video/v3/standard/text-to-video`, `fal-ai/stable-audio-25/text-to-audio`, `fal-ai/mmaudio-v2`.
- Prüfen nach dem Update: Sind die Endpunkte inzwischen in der Preistabelle (`model_prices_and_context_window.json`, Schlüssel `fal_ai/<endpoint>`), oder kann man eigene Preise in `litellm_config.yaml` eintragen, die die Route akzeptiert?
- Wenn ja: video-mcp und sound-mcp auf `<LiteLLM>/fal_ai/...` umstellen, `mcp_cost_hook.py` und `FAL_KEY` in den MCPs entfallen. Achtung: Die fal-Antwort enthält `queue.fal.run`-URLs in `status_url`/`response_url`, die müssen auf die LiteLLM-Route umgeschrieben werden.

### Kostenbremsen
- LiteLLM: Max Budget + monatlicher Reset für `image-mcp-service` und `video-mcp-service` (z. B. 10 $/Monat).
- fal.ai: nur kleines Guthaben aufladen bzw. Limit im Dashboard setzen.
- ElevenLabs: Nutzungslimit am API-Key prüfen.

### image_to_video im Video-MCP
- Neues Werkzeug `image_to_video(image, prompt, provider)`: Bild aus `/data/output` → Video.
- Kling v3 Pro Image-to-Video über fal (`fal-ai/kling-video/v3/pro/image-to-video`, ca. 0,112 $/s ohne Ton).
- Bild als Data-URI übergeben (fal erreicht den Tailnet-Dateiserver nicht).
- Möglicher Ablauf: Bild erzeugen → bearbeiten → Video → `add_audio_to_video`.

### Weniger strenges Bild-Bearbeiten
- FLUX Kontext oder Seedream Edit über fal als Anbieter für `edit_image`.
- Erst prüfen, ob LiteLLM diese Modelle für `/images/edits` unterstützt. Sonst direkt über fal wie beim Sound-MCP.

### Transparenter Hintergrund im Image-MCP
- Parameter `transparent=true` für `generate_image` (Presets ab 30.09.2026 vorhanden, siehe README).
- openai: `background="transparent"` + `output_format="png"` durchreichen. Vorher testen, ob gpt-image-2 das über LiteLLM kann, sonst Rückfall ohne Transparenz.
- Andere Provider: Hintergrund entfernen mit `rembg` (Image ca. +200 MB, RAM prüfen).

### LiteLLM Skills in OpenCode
- Fertige Skill-Sammlung „LiteLLM Skills“ (https://docs.litellm.ai/docs/tutorials/claude_code_skills): Agent verwaltet den Proxy per `curl` (Keys, Teams, Modelle, MCP-Server, Nutzung).
- Achtung: braucht den Admin-Key → nur mit Bestätigung jedes Befehls nutzen; ggf. eigenen Key mit eingeschränkten Rechten prüfen.

### Eigener Medien-Skill
- Skill (`SKILL.md`) für den Ablauf Bild → Bearbeiten → Video → Ton mit den bevorzugten Anbietern und Kostenhinweisen.
- Vorher prüfen, ob eine Anweisung in der OpenCode-Konfiguration nicht schon reicht.

### OpenCode 2 (sobald stabil)
- Stand 27.09.2026: v2 ist Beta (2.0.6). Server bleibt bis dahin auf 1.18.x (`OPENCODE_VERSION` in `.env`, kein Auto-Update).
- Achtung: Das lokale Windows-OpenCode aktualisiert sich selbst. Springt es auf v2, geht `opencode attach` zum v1-Server vermutlich nicht mehr (neue Server-/Client-API). Browser-UI ist nicht betroffen. Dann lokal auf 1.18.x pinnen oder Server umstellen.
- Umstieg: zweiten Test-Container (anderer Port, Kopie von `data/`) aufsetzen, testen, dann umstellen.
- Prüfen: offizielles Image `ghcr.io/anomalyco/opencode` statt eigenem Dockerfile? (Braucht zusätzlich `gh`, UID 1001, `xdg-open`-Workaround.) Web-UI-Befehl in v2: `opencode pair`.
- Config: v2 liest `opencode.json` weiter und übersetzt Provider (`npm` → `package`) und MCP (`mcp.servers`) im Speicher. `update-models.py` ggf. auf das neue Format anpassen.
- V1-Plugins laufen in v2 nicht (betrifft `caveman-native.js` des Host-Users, nicht den Container).
- Doku: https://opencode.ai/v2/docs/migrate-v1/

### Fehlermeldungen der MCPs sichtbar machen
- Alle MCPs nutzen `mcp==2.2.0`. Dort erreicht nur `ToolError` das Modell, ein `ValueError` wird zu `Error executing tool <name>`.
- Betroffen: `raise ValueError` in image-, media-, memory-, monitor-, paperless-, sound- und video-mcp (teils intern abgefangen, einzeln prüfen). Auf `ToolError` umstellen, wie im web-mcp.

### Healthchecks Stufe 3
- Noch ohne Healthcheck: backrest, beszel, beszel-agent, crowdsec, npmplus-anubis, open-archiver, beide meilisearch, beide tika, gotenberg, headroom. Vorher prüfen, ob das Image `wget`/`curl` hat und welcher Endpunkt taugt.
- Open Archiver: veraltetes `version: "3.8"` aus `docker-compose.yml` entfernen (Warnung bei jedem compose-Aufruf).

### Obsidian-Suche: Nacharbeiten
- Optional `hot.md` mit laufenden Themen als Einstieg pro Sitzung. („Vault zuerst durchsuchen“-Regel steht seit 02.10.2026 in beiden `CLAUDE.md` und in `AGENTS.md`.)
- `MIN_SIMILARITY` (0.4) nach einigen Wochen Nutzung prüfen. Lange Fragen in ganzen Sätzen streuen stärker (viele Treffer um 0.44–0.46); kurze Stichwörter treffen besser.

### Aufräumen Obsidian-Vault (Nextcloud)
- Ordner `Obsidian ` (Leerzeichen am Ende, von Remotely Save angelegt) in der Nextcloud-Weboberfläche löschen – unter Windows nicht möglich.
- Ordner `Projekte/PowerShell/` (großes S) löschen: Doppel zu `Projekte/Powershell/`, entstanden am 02.10.2026 per `save_note`. Windows unterscheidet keine Groß-/Kleinschreibung, Nextcloud synct ihn deshalb nicht auf den PC. Spiegelpfad ist immer `Projekte/Powershell/…` (wie der Repo-Ordner). Löschen nur über die Weboberfläche, der MCP kann nicht löschen.

### Weitere MCP-Ideen
- Linkwarden-MCP (Lesezeichen suchen/hinzufügen), Open-Archiver-MCP (Mails suchen, nur lesend).
- `monitor_mcp` um `backup_status` (Backrest) und Verlauf aus Beszel erweitern.

### Kleinere Punkte
- `ha_mcp` liefert 130 Tools (jede Anfrage schickt alle mit) → in HA nur nötige Entitäten für Assist freigeben.
- Lokaler OpenCode-Key (Windows-Config) sieht nur einen Teil der MCP-Tools (sound: 2/5, image: 1/5, video: 2/4, z. B. fehlen `edit_image`, `generate_music`, `sound_status`): in LiteLLM beim Team alle Tools freigeben und am Key die MCP-Liste leer lassen (oder dort ebenfalls alle Tools). Nur nötig, wenn das lokale OpenCode weiter genutzt wird.
- Seedream v4 statt v3, sobald LiteLLM es in der Modellliste führt.
- ElevenLabs Music als zweiter Anbieter für `generate_music`.
- Runway Gen-4.5 über LiteLLM als dritter Video-Anbieter (Kosten dann in LiteLLM/HA sichtbar).
- HA-Sensor „Budget genutzt“ auf Monatskosten umstellen, falls das LiteLLM-Budget alle 30 Tage zurückgesetzt wird.
- `litellm-mcp/README.md` um `github_mcp` und `playwright_mcp` ergänzen (seit 01.10.2026 eingebunden).

## Erledigt

- **03.10.2026 – Hermes-Skill `/mcp_freigaben`** (nur lesend): `report(section="freigaben")` im monitor_mcp über den Nur-Lese-Key `LITELLM_VIEWER_KEY` (proxy_admin_viewer). Zeigt, welche MCP-Server der Key `hermes-ha` (oder sein Team) nutzen darf, und gleicht die eigenen Tools des Monitors mit der Allowlist am Server und den Tool-Rechten am Key ab. Fremde Server: nur freigegeben ja/nein, deren vollständige Tool-Liste sieht der Nur-Lese-Key nicht.
- Obsidian-MCP Hybrid-Suche (02.10.2026): SQLite-FTS5 + Embeddings `text-embedding-3-small` über LiteLLM (Key `obsidian-mcp-service`, Service Account, Team `mcp-services`), Reciprocal Rank Fusion, Abgleich per ETag. `Arbeit/`, `Privat/`, `Finanzen/` und `privat: true` gehen nicht an OpenAI. QMD (Hermes-Setup eines Kollegen) bewusst nicht genommen: lokale Modelle ~1 GB, gleiches RAM-Problem wie Ollama. Details: `litellm-mcp/README.md`.
- Obsidian-Vault Ordnerstruktur (02.10.2026): `Projekte/`, `KI/`, `Wissen/`, `Haus/`, `Einkauf/`, `Reisen/`, `Inbox/`, `Arbeit/`, `Privat/`, `Finanzen/`, `Archiv/` (je mit `README.md`).
- Healthchecks Stufe 1+2 (28.09.2026): litellm, alle MCPs, image-mcp-files, opencode-server, media-browser, Postgres/Valkey von Linkwarden, Open Archiver, Paperless (+ depends_on service_healthy)
- Web-MCP `web_mcp` (Perplexity-Suche über LiteLLM, `fetch_url` mit Sperre interner Adressen) und Context7 `context7_mcp` für OpenCode und Claude Code (28.09.2026)
- HA-Sensoren für LiteLLM über `100.105.233.113:4001`
- Sound-MCP: ElevenLabs, Cassette, Stable Audio, Musik, MMAudio, Auftragssystem gegen 60-s-Timeout
- Video-MCP: Veo + Kling (fal), Anbieter-Rückfrage, Umgang mit Ablehnungen
- Image-MCP: openai, gemini, seedream, flux, `edit_image`
- Alle MCPs: Kosten-Log `.costs.jsonl` + `cost_summary`, doppelte Aufträge verhindern (`variation`), `curl`-Download-Hinweis
- Image-MCP: 40-s-Warten + `image_status` gegen 60-s-Timeout, altes `generate_video` entfernt
- Video-Worker räumt Statusdateien nach 30 Tagen auf; nginx liefert keine versteckten Dateien mehr aus
- fal-Kosten (Kling, Sounds, MMAudio) werden per LiteLLM-Plugin `mcp_cost_hook.py` in LiteLLM gebucht und erscheinen damit in HA
- Medien-Übersicht `media-browser` auf :8793 (abspielen, filtern, löschen); nginx liefert `.wav` als `audio/wav`
- OpenCode läuft zentral als Docker-Server auf :4096 (siehe `OpenCode-Server.md`), Modellabgleich per `update-models.py`
- Medien-Übersicht: Upload + Filter „älter als X Tage“; automatisches Löschen der Medien nach 30 Tagen abgeschaltet (`image-mcp-cleanup` räumt nur noch `.jobs/` auf)
- Home-Assistant-MCP `ha_mcp` (HA-Integration, eigener HA-Benutzer, Skript-IDs max. 42 Zeichen)
- Paperless-MCP `paperless_mcp` (nur lesend, eigener Stack)
- Medien-MCP `media_mcp` (ffmpeg: trim, concat, convert, image_to_video, add_audio, extract_audio)
- `elevenlabs/eleven_v3` und andere Nicht-Chat-Modelle werden von `update-models.py` und `Update-OpenCodeLiteLLM.ps1` nicht mehr eingetragen
- Team des OpenCode-Server-Keys: alle Tools von `image_mcp`, `video_mcp`, `sound_mcp` freigegeben (vorher nur `generate_*`/`list_*`)

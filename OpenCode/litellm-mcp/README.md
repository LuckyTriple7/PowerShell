# LiteLLM MCPs – lokale Kopie

Spiegel von `vserv01:/opt/docker/stacks/litellm-caveman` (ohne `.env`, Backups und `compose.yml`, das nur root lesen darf).

| Ordner | Container | Inhalt |
|---|---|---|
| `image-mcp/` | `litellm-image-mcp`, `litellm-image-mcp-files` (nginx) | Bilder erzeugen/bearbeiten, `cost_summary` |
| `video-mcp/` | `litellm-video-mcp`, `litellm-video-mcp-worker` | Veo + Kling (fal), Worker lädt fertige Videos |
| `sound-mcp/` | `litellm-sound-mcp` | Soundeffekte, Musik, Ton für Videos |
| `paperless-mcp/` | `litellm-paperless-mcp` (eigener Stack) | Paperless-ngx durchsuchen und lesen, **nur lesend** |
| `media-mcp/` | `litellm-media-mcp` (eigener Stack) | Medien mit ffmpeg bearbeiten, lokal und kostenlos |
| `monitor-mcp/` | `litellm-monitor-mcp`, `litellm-monitor-docker-proxy` (eigener Stack) | Server überwachen: CPU/RAM, Container, APT, Image-Updates, Fehler, **nur lesend** |
| `memory-mcp/` | `litellm-memory-mcp` (eigener Stack) | Gemeinsames Gedächtnis aller KI-Clients (SQLite + Volltextsuche) |
| `web-mcp/` | `litellm-web-mcp` (eigener Stack) | Websuche (Perplexity über LiteLLM) und Webseiten als Markdown lesen, interne Adressen gesperrt |
| `obsidian-mcp/` | `litellm-obsidian-mcp` (eigener Stack) | Obsidian-Vault in Nextcloud lesen, schreiben, durchsuchen (WebDAV über Tailscale) |
| `uptime-kuma-mcp/` | `litellm-uptime-kuma-mcp` (eigener Stack, fertiges Image) | Uptime Kuma v2 (HA): Monitore, Heartbeats, Benachrichtigungen, Wartung, Statusseiten – **nur OpenCode** |
| (extern) | – | `context7_mcp`: aktuelle Doku zu Bibliotheken/APIs, gehostet von Upstash (`https://mcp.context7.com/mcp`) |
| (in tuiwatch) | `tuiwatch` (Stack `tuiwatch`) | `tuiwatch_mcp`: Reiseangebote, Trips, Flugsuche, Preise, Status – 14 Tools, nur lesend. MCP ist in die TUIWatch-App eingebaut (Token-Auth), gebaut in einer anderen Sitzung |

## Vom Server aktualisieren

```bash
S=/opt/docker/stacks/litellm-caveman
for f in image-mcp/Dockerfile image-mcp/nginx.conf image-mcp/server.py \
         sound-mcp/Dockerfile sound-mcp/server.py \
         video-mcp/Dockerfile video-mcp/server.py video-mcp/worker.py \
         compose.video-mcp.yml litellm_config.yaml; do
  scp -i ~/.ssh/vserv01-opencode "opencode@vserv01:$S/$f" "$f"
done
```

Der User `opencode` hat nur Lesezugriff. Änderungen werden weiterhin als root auf dem Server eingespielt.

## LiteLLM: Version, Anmeldung, Notfall

- **Version**: `ghcr.io/berriai/litellm:v1.103.0` (Stand 28.09.2026). Der Tag steht fest in `compose.yml` (Dienst `litellm`), nicht in `.env`.
- **Update**: vorher DB sichern, dann Tag ändern und nur `litellm` neu starten. Migrationen laufen beim Start automatisch. **Nie** `--remove-orphans` verwenden.
  ```bash
  cd /opt/docker/stacks/litellm-caveman
  docker exec litellm-db sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > backups/litellm-db-$(date +%F-%H%M)-vALT.sql.gz
  sed -i 's#litellm:vALT#litellm:vNEU#' compose.yml
  docker compose pull litellm && docker compose up -d litellm
  ```
  Danach `docker logs litellm` prüfen (Zeile `mcp_cost_hook: geladen`) und `check-tool-names.py` laufen lassen (alle MCPs mit Tools?).
- **Zurück auf die alte Version**: alten Tag wieder eintragen, `docker compose up -d litellm`. Wenn die DB nicht mehr passt, den Dump aus `backups/` einspielen. Nächtliche Dumps macht `litellm-db-backup.timer` (23:40).
- **Anmeldung in der Oberfläche** nur mit persönlichem Admin-Benutzer (E-Mail + eigenes Passwort, Rolle `Admin`). Die Anmeldung mit `UI_USERNAME`/`UI_PASSWORD` bzw. Master-Key ist abgeschaltet: `general_settings.disable_env_credential_login: true` in `litellm_config.yaml`. API-Keys (OpenCode, HA, MCPs, Caveman) sind davon nicht betroffen.
- **Einladungslinks** nutzen `PROXY_BASE_URL` (im `environment` von `litellm` in `compose.yml`). Fehlt sie, zeigen die Links auf `http://0.0.0.0:4000`.

### Rettungsanker: aus der Oberfläche ausgesperrt

Passwort des Admin-Benutzers vergessen oder Benutzer gelöscht → Env-Anmeldung vorübergehend wieder einschalten:

```bash
cd /opt/docker/stacks/litellm-caveman
sed -i 's/disable_env_credential_login: true/disable_env_credential_login: false/' litellm_config.yaml
docker compose restart litellm
```

Dann mit `UI_USERNAME` (`admin`)/`UI_PASSWORD` aus `.env` anmelden (bleiben dafür absichtlich in `.env` stehen, seit 28.09.2026 auch in `compose.yml` an `litellm` übergeben), Admin-Benutzer reparieren oder neu einladen, danach wieder auf `true` stellen und `docker compose restart litellm`.

## Medien-Übersicht (Port 8793)

Eigener Stack `vserv01:/opt/docker/stacks/media-browser`, lokale Kopie in [`../media-browser/`](../media-browser/).

- `https://vserv01.tailf89473.ts.net:8793`: alle erzeugten Bilder, Sounds und Videos als Karten mit Player/Vorschau, Filter nach Typ und Alter („älter als X Tage“), Suche, Löschen (einzeln, Auswahl oder „Alle auswählen“).
- **Hochladen** per Button oder Ziehen ins Fenster: Bilder, Audio, Video, bis `MAX_UPLOAD_MB` (Standard 300). Name wird zu `<datum>-upload-<name>.<ext>`. Hochgeladene Dateien kann man direkt an `edit_image` bzw. `add_audio_to_video` geben (Dateiname genügt).
- Automatisch gelöscht werden keine Medien mehr (seit 27.09.2026). Der Dienst `image-mcp-cleanup` in `compose.yml` hat früher alles in `/data/output` nach 30 Tagen gelöscht (`find /data/output -type f -mmin +43200 -delete`, täglich). Jetzt räumt er nur noch `/data/output/.jobs` auf. Der Video-Worker entfernt zusätzlich Statusdateien in `/data/state` nach 30 Tagen. Medien löscht man selbst über die Übersicht (Filter „älter als“).
- Kleiner Python-Server (`app.py`, nur Standardbibliothek) auf dem Volume `litellm-caveman_image-mcp-output`. Er listet, nimmt Uploads an und löscht. Abgespielt wird über den nginx-Dateiserver auf 8792, der Spulen (Range) unterstützt.
- Versteckte Dateien (`.costs.jsonl`, `.jobs/`, …) werden weder angezeigt noch gelöscht. Lösch- und Upload-Anfragen mit fremdem `Origin` werden abgelehnt.
- Port `127.0.0.1:8793`, im Tailnet über `tailscale serve --bg --https=8793 http://127.0.0.1:8793`.
- Optionales Passwort: `MEDIA_PASSWORD` in `.env` (Benutzername beliebig), dann `docker compose up -d`.
- Läuft im Container als root (die MCP-Dateien gehören root), aber `read_only`, `cap_drop: ALL`, `no-new-privileges`.
- Filebrowser wurde bewusst nicht genommen: seit 31.08.2026 archiviert, bekannte Lücken bleiben offen.

Der nginx-Dateiserver liefert `.wav` als `audio/wav` aus (`image-mcp/nginx.conf`), sonst lädt der Browser WAVs nur herunter. Nach Änderungen an `nginx.conf`: `docker exec litellm-image-mcp-files nginx -s reload`. Zeigt der Browser danach noch das alte Verhalten, liegt es am Cache (Strg+F5).

## Image-MCP: Zielformate (`preset`, `resize_image`)

Die Bildmodelle liefern nur ca. 1024 px (gpt-image: `1024x1024`, `1536x1024`, `1024x1536`; Gemini ignoriert `size` teils), als PNG oft mehrere MB. Seit 30.09.2026 schneidet der MCP danach mit Pillow auf das Ziel zu. Das kostet nichts extra.

- `generate_image` / `edit_image`: Parameter `preset` oder frei `width`, `height`, `format` (png/jpg/webp), `max_kb`. Nur Breite oder nur Höhe skaliert proportional, beides schneidet mittig auf das Seitenverhältnis zu. Die Modellgröße (quer/hoch/quadratisch) wird passend zum Ziel gewählt. Das ungeschnittene Bild bleibt erhalten (Link „Ungeschnitten“).
- Presets:

  | preset | Ergebnis |
  |---|---|
  | `telegram_avatar` | 512×512 PNG, Motiv mittig (Telegram schneidet rund) |
  | `telegram_sticker` | 512×512 WebP, max. 512 KB |
  | `logo` | 1024×1024 PNG |
  | `icon` | 256×256 PNG + `.ico` (256…16) |
  | `ha_addon_icon` | 128×128 PNG (`icon.png` eines Add-ons) |
  | `ha_addon_logo` | 250×100 PNG (`logo.png` eines Add-ons) |
  | `ha_brand_icon` | 256×256 PNG + `@2x` 512×512 (brands-Repo `icon.png`/`icon@2x.png`) |
  | `social` / `story` | 1080×1080 / 1080×1920 JPG |
  | `banner` | 1500×500 JPG |
  | `thumbnail` / `youtube_banner` | 1280×720 / 2560×1440 JPG |
  | `wallpaper` | 1920×1080 JPG |
  | `original` | unverändert (Standard, wie vorher) |

- Logo-, Icon-, Avatar-, Sticker- und HA-Presets hängen einen Design-Hinweis an den Prompt (flach, mittig mit Rand, einfarbiger Hintergrund, keine kleine Schrift).
- Das Modell fragt Provider und Zweck in einer Frage ab, außer beides ist schon klar („Logo für Telegram-Bot“).
- `resize_image`: bringt vorhandene Bilder ohne KI-Aufruf auf ein Preset oder eine freie Größe. Quelle: Dateiname/Link aus `list_images`, Upload aus der Medien-Übersicht (Dateiname genügt), beliebiger http(s)-Link oder `data_base64`. Max. 25 MB.
- `list_images` zeigt jetzt auch die Pixelmaße.
- Transparenter Hintergrund: noch nicht, kommt später (siehe Backlog).

## Paperless-MCP (`paperless_mcp`)

Eigener Stack `vserv01:/opt/docker/stacks/paperless-mcp`, lokale Kopie in [`paperless-mcp/`](paperless-mcp/).

- Tools: `search_documents` (Volltext + Filter Tag/Korrespondent/Typ/Datum), `get_document` (Metadaten, Notizen, OCR-Text, gekürzt auf 8000 Zeichen), `recent_documents`, `list_metadata`.
- Nur lesend: Der Server ruft ausschließlich GET-Endpunkte auf.
- Hängt in `litellm-caveman_default` (für LiteLLM) und `paperless-ngx_default` (erreicht `http://paperless-ngx-webserver-1:8000`).
- `.env`: `PAPERLESS_TOKEN` (eigener API-Token, weil ein Zweitbenutzer fremde Dokumente nicht sieht), `PAPERLESS_PUBLIC_URL` (für Links), `PAPERLESS_HOST_HEADER` (nur falls Paperless mit 400 antwortet, weil `ALLOWED_HOSTS` greift).
- In LiteLLM: `paperless_mcp`, URL `http://litellm-paperless-mcp:8000/mcp`, keine Authentifizierung, am Team freigegeben.
- **Schwärzung** (`redact.py`, Standard an): Persönliche Daten werden im MCP ersetzt, bevor sie das Modell sehen. Wichtig, weil auch Free-Modelle (`or-free`) den MCP nutzen.
  - Eigene Begriffe aus `.env`: `REDACT_NAMES` → `[NAME]`, `REDACT_TERMS` (eigene Adresse, Ort, Kennzeichen, …) → `[PRIVAT]`, getrennt mit `;`. Tolerant gegen ß/ss, ä/ae, Str./Straße, Groß/klein und Zeilenumbrüche. Vor- und Nachnamen zusätzlich einzeln eintragen.
  - Muster: `[EMAIL]`, `[IBAN]` (jede `DE`-IBAN automatisch, auch mit Umbruch, `-`, `.` oder klein geschrieben; andere Länder in Vierergruppen), `[TELEFON]`, `[STRASSE]` (Straße + Hausnummer), `[PLZ ORT]`, `[GEBURTSDATUM]`, `[STEUER-ID]`, `[SV-NR]`, `[NUMMER]` (Kunden-, Vertrags-, Versicherten-, Konto-, Mitgliedsnummer mit Stichwort).
  - Betrifft Titel, OCR-Text, Notizen, Dateiname und Suchtreffer-Ausschnitte. Korrespondenten, Tags und Typen bleiben lesbar, außer sie enthalten eigene Begriffe.
  - Die Suche selbst läuft ungeschwärzt in Paperless, nur die Ausgabe wird geschwärzt.
  - Grenzen: OCR-Fehler können durchrutschen, fremde Personennamen erkennt nur die Liste, nicht ein Muster.
  - Abschalten: `REDACT=off` in `.env`, dann `docker compose up -d`.

## Medien-MCP (`media_mcp`)

Eigener Stack `vserv01:/opt/docker/stacks/media-mcp`, lokale Kopie in [`media-mcp/`](media-mcp/).

- ffmpeg im Container, arbeitet auf dem gemeinsamen Volume `litellm-caveman_image-mcp-output` (`/data/output`). Ergebnisse erscheinen sofort in der Medien-Übersicht und lassen sich an die anderen MCPs weitergeben.
- Tools: `trim`, `concat` (Videos werden auf die Größe des ersten skaliert, fehlender Ton wird zu Stille), `convert` (mp3/wav/ogg/m4a/flac/mp4/webm/gif/png/jpg/webp, optional Breite), `image_to_video` (optional mit Audio und Zoom-Effekt), `add_audio` (ersetzen oder mischen, Lautstärke, Schleife), `extract_audio`, `media_info`, `list_media`, `media_status`.
- Originale bleiben immer erhalten. Neue Dateien heißen `<zeit>-<aktion>-<name>-<kennung>.<ext>`. Während der Arbeit schreibt ffmpeg in eine versteckte `.tmp-…`-Datei.
- Längere Aufträge (> 40 s) liefern einen `job_ref` → `media_status`. Laufende Aufträge gehen bei einem Neustart des Containers verloren.
- Grenzen: max. 15 min Laufzeit pro Auftrag, 2 CPUs, 2 GB RAM, `concat` max. 20 Dateien.
- In LiteLLM: `media_mcp`, URL `http://litellm-media-mcp:8000/mcp`, keine Authentifizierung, am Team freigegeben.

## Monitor-MCP (`monitor_mcp`)

Eigener Stack `vserv01:/opt/docker/stacks/monitor-mcp`, lokale Kopie in [`monitor-mcp/`](monitor-mcp/).

- Tools: `health_check` (Kurzfassung, Warnungen zuerst), `server_overview` (CPU, Last, RAM, Swap, Platten, Neustart nötig, größte Prozesse), `container_stats` (nach RAM/CPU, optional je Stack), `failed_services` (systemd, kaputte Container, Journal-Fehler 24 h), `apt_updates`, `image_updates` (Digest-Vergleich mit Docker Hub/ghcr, optional neuere Versions-Tags), `crowdsec_status` (lokale Sperren, Blocklisten, Alerts 24 h, Bouncer/Maschinen, Hub-Updates; Daten per `cscli … -o json` vom Host-Sammler), `maintenance_status` (seit 03.10.2026: Backups, TLS-Zertifikate, Docker-Speicher; `section` = all/backups/certs/docker). Die Warnungen daraus stehen auch in `health_check` und damit im Hermes-Morgenbericht.
- **`report(section)`** (seit 03.10.2026): fertig formatierter deutscher Bericht mit Ampel und To-do, `section` = check/ressourcen/updates/sicherheit. Die Hermes-Skills `vserv01-*` rufen nur dieses Tool auf und reichen das Ergebnis unverändert weiter, weil Qwen beim Zusammenbauen Befehle wegließ. Die LiteLLM-Version prüft der MCP selbst (`http://litellm:4000/openapi.json` gegen die GitHub-Releases, 1 h Cache, `LITELLM_URL`).
- **Mailcow** (seit 03.10.2026): Mailcow-Container (Compose-Ordner enthält `mailcow`) prüft `image_updates` nicht mehr einzeln (Status `managed`), weil Mailcow seine Images selbst pinnt. Stattdessen vergleicht der MCP die installierte Version (`$MAILCOW_GIT_VERSION` aus `data/web/inc/app_info.inc.php`, liest der Host-Sammler) mit den GitHub-Releases. Update immer per `./update.sh`.
- **Kosten** (`report(section="kosten")`, seit 03.10.2026): heute/gestern/Monat, je Key mit Budget (Warnung ab 80 %), Top-Modelle. Quelle `/user/daily/activity/aggregated` und `/key/list` über einen Nur-Lese-Key mit Rolle `proxy_admin_viewer` (`LITELLM_VIEWER_KEY` in der `.env` des Stacks, angelegt mit `New-LiteLLMHomeAssistantKey.ps1 -Alias monitor-mcp`). Hermes-Skill `litellm-kosten`.
- **Backups:** alle systemd-Timer mit `backup`/`dump` im Namen. Warnung, wenn der Timer nicht aktiv ist, der letzte Lauf fehlschlug oder älter als 26 h ist (`BACKUP_MAX_AGE_HOURS`). **Backrest** (seit 03.10.2026): Der Host-Sammler kopiert `/opt/docker/stacks/backrest/data/oplog.sqlite` (+ -wal/-shm) und wertet die Kopie aus (Protobuf-Feld 100 = Backup, 103 = Prune, 107 = Check; Status 3 = ok, 7 = Warnung, 4 = Fehler; Feldnummern aus backrest `proto/v1/operations.proto`). Je Plan der letzte Backup-Lauf (Warnung ab 26 h), je Repo Check/Prune (Warnung ab 35 Tagen). Keine API, kein Passwort nötig.
- **Zertifikate:** `/opt/npmplus/tls/**/fullchain*.pem` und das Mailcow-`cert.pem`. Pro Namensliste zählt das neueste. Bei NPMplus zählt, was nginx per SNI auf `159.195.246.83:443` ausliefert (auf 127.0.0.1 lauscht nginx nicht). Dateien, die nginx nicht ausliefert (gelöschte Proxy-Hosts), lösen keinen Alarm aus. Warnung, wenn nur noch 1/3 der Laufzeit übrig ist: Short-Lived-Zertifikate (6,7 Tage) ab 2,2 Tagen, 90-Tage-Zertifikate ab 30 Tagen.
- **Anmeldungen** (seit 03.10.2026): SSH (`journalctl -t sshd -t sshd-session -t sshd-auth`) und sudo der letzten 24 h. Rot: erfolgreiche SSH-Anmeldung von außerhalb Tailscale/LAN/Docker (Netze fest in `TRUSTED_NETS`, nicht `is_private`). Gelb: über 20 fehlgeschlagene Anmeldungen, abgelehnte sudo-Befehle.
- **Tailscale:** `tailscale status --json`. Rot: vserv01 nicht verbunden. Gelb: Gerät aus `TAILSCALE_REQUIRED` offline (Standard `raspberrypi,homeassistant`), Key läuft in unter 14 Tagen ab, Health-Meldung (außer `TAILSCALE_HEALTH_IGNORE`, Standard `accept-routes`, das ist bewusst aus).
- **Mail-Warteschlange:** `postqueue -j` im Postfix-Container von Mailcow, Empfänger nur als Domain. Gelb: Mails älter als 1 h oder hold. Rot: über 50 Mails oder älter als 24 h.
- **Docker-Speicher:** `docker system df`. Warnung ab 20 GB freigebbar in Images + Build-Cache (`WARN_DOCKER_RECLAIM_GB`).
- Nur lesend. Der MCP ändert nichts und nennt nur die Befehle, die man als root ausführt.
- **Host-Daten** (APT, systemd, Platten, Journal, Prozesse) sammelt `server-status.timer` alle 10 min als root, und zwar mit `/usr/local/sbin/server-status-collect` nach `/var/lib/server-status/status.json`. Die Datei ist read-only in den Container gemountet. `apt-get update` macht weiterhin `apt-daily.timer`.
- **Docker** über `tecnativa/docker-socket-proxy` (nur `CONTAINERS`, `IMAGES`, `INFO`, kein POST) im internen Netz `proxy_net`. Aus `inspect` liest der MCP nur Zustandsfelder, keine Env-Variablen.
- CPU und RAM des Hosts kommen per `psutil` aus `/proc` (zeigt im Container die Werte des Hosts).
- Image-Prüfung: Ergebnis 6 h zwischengespeichert (`IMAGE_CACHE_HOURS`). Sie läuft im Hintergrund weiter, wenn sie länger als 40 s dauert. Lokal gebaute Images (die MCPs) sind nicht prüfbar.
- `IMAGE_IGNORE` in `.env` des Stacks (kommagetrennt): Für diese Images werden keine neueren Versions-Tags gesucht, weil das Projekt die Version selbst festlegt. Neu gebaute Images mit demselben Tag (Digest) meldet der MCP weiterhin. Ohne Tag gilt ein Eintrag für alle Tags, mit `*` am Ende für alles darunter. Stand: `getmeili/meilisearch,apache/tika,ghcr.io/mailcow/*,mariadb:10.11,redis:7.4.11-alpine` (Open Archiver, Linkwarden, Mailcow).
- In LiteLLM: `monitor_mcp`, URL `http://litellm-monitor-mcp:8000/mcp`, keine Authentifizierung, am Team freigegeben.

## Memory-MCP (`memory_mcp`)

Eigener Stack `vserv01:/opt/docker/stacks/memory-mcp`, lokale Kopie in [`memory-mcp/`](memory-mcp/). **Einrichtung/Neuinstallation: [`memory-mcp/SETUP.md`](memory-mcp/SETUP.md).**

- Gemeinsames Langzeitgedächtnis für Claude Code (Windows, Webtop) und OpenCode, damit die Notizen nicht mehr pro Rechner auseinanderlaufen.
- Tools: `remember`, `recall` (Volltextsuche FTS5, bm25), `get_memory`, `update_memory` (alte Fassung → `memory_history`), `forget` (nur als gelöscht markiert, wiederherstellbar), `list_memories`, `import_markdown` (Frontmatter-Datei = 1 Eintrag, sonst je Überschrift; Duplikate werden übersprungen), `export_markdown`.
- Daten: `data/memory.db` (Bind-Mount, gehört `nobody`, landet damit im Backrest-Backup), täglich `data/backup/memory-JJJJ-MM-TT.db` per `VACUUM INTO`, 14 Tage aufbewahrt.
- In LiteLLM: `memory_mcp`, URL `http://litellm-memory-mcp:8000/mcp`. `forget` war in 1.102 standardmäßig gesperrt und musste am Server und am Team freigegeben werden.
- Claude Code: eigener Key `claude-code-memory` (AI APIs, Service Account, nur `memory_mcp`), eingebunden mit `claude mcp add --scope user --transport http memory https://vserv01.tailf89473.ts.net:4000/memory_mcp/mcp --header "x-litellm-api-key: Bearer …"`. Anweisung in `~/.claude/CLAUDE.md`.
- OpenCode: Anweisung in `data/config/AGENTS.md` (Vorlage [`../opencode-server/AGENTS.md`](../opencode-server/AGENTS.md)).
- Import 27.09.2026: alle Claude-Notizen von Windows (115 Einträge, Projekte `ha-addons`, `ha-customintegrations`, `dockergames`, `vserv01`, `strato-dyndns`, `powershell`, `ubuntu-docker`).

## Web-MCP (`web_mcp`)

Eigener Stack `vserv01:/opt/docker/stacks/web-mcp`, lokale Kopie in [`web-mcp/`](web-mcp/).

- Tools: `web_search` (Titel, URL, Datum, Ausschnitt; optional `domains`), `fetch_url` (Hauptinhalt als Markdown per trafilatura, lange Seiten in Teilen über `start`, 10 min Cache, max. 5 MB, 5 Weiterleitungen).
- Suche über LiteLLM: `POST http://litellm:4000/v1/search/<SEARCH_TOOL>`. Das Such-Tool `Perplexity` ist in der UI unter **Search Tools** angelegt (in der DB, nicht in `litellm_config.yaml`). Dort steht der echte Perplexity-Key: `os.environ/PERPLEXITYAI_API_KEY` funktioniert bei Such-Tools aus der UI **nicht** (401).
- Key: `WEB_MCP_LITELLM_KEY` in `.env` = LiteLLM-Key `web-mcp-service` (Team `mcp-services`, Budget 5 $/30 Tage). Suchkosten werden diesem Key gebucht.
- **Schutz:** `fetch_url` lädt nur öffentliche Adressen. Jede Adresse und jede Weiterleitung wird aufgelöst, private, Docker-, Tailnet- (100.64/10), Loopback- und Link-Local-Adressen werden abgelehnt. Die Verbindung geht an die geprüfte IP (Host-Header + SNI), damit DNS-Rebinding nicht greift.
- Fehler als `ToolError`, damit das Modell die Meldung sieht (siehe Stolperstein unten).
- In LiteLLM: `web_mcp`, URL `http://litellm-web-mcp:8000/mcp`, keine Authentifizierung, am Team freigegeben.

Test direkt am Container (als root):

```bash
IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "litellm-caveman_default").IPAddress}}' litellm-web-mcp)
curl -s http://$IP:8000/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream'   -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fetch_url","arguments":{"url":"https://example.com"}}}'
```

## Obsidian-MCP (`obsidian_mcp`)

Eigener Stack `vserv01:/opt/docker/stacks/obsidian-mcp`, lokale Kopie in [`obsidian-mcp/`](obsidian-mcp/). Seit 29.09.2026.

- Vault = Ordner `Obsidian` in der Nextcloud (HA-Add-on zu Hause). Obsidian selbst läuft nur auf PC/Handy, der PC synchronisiert per Nextcloud-Client, Android per Plugin Remotely Save (WebDAV).
- Zugriff nur per **WebDAV** (`https://100.89.90.114:7443/remote.php/dav/files/andreas.waidele@gmx.de/Obsidian/`) über Tailscale. Nie direkt ins Nextcloud-Datenverzeichnis schreiben, sonst sieht Nextcloud die Dateien erst nach `occ files:scan`.
- Anmeldung: App-Passwort `obsidian-mcp`, `.env` → `NEXTCLOUD_APP_PASSWORD` (chmod 600). Benutzer = E-Mail-Adresse.
- **TLS:** Nextcloud hat das selbstsignierte LSIO-Zertifikat (CN=*, keine SAN, gültig bis 2036). Der MCP holt es beim Start, vergleicht den SHA256-Fingerprint mit `NEXTCLOUD_CERT_SHA256` in `compose.yml` und vertraut danach nur genau diesem Zertifikat. Passt der Fingerprint nicht, startet der Container nicht (Log: `Nextcloud-Zertifikat hat Fingerprint …`). Nach einem Zertifikatswechsel neuen Fingerprint eintragen: `echo | openssl s_client -connect 100.89.90.114:7443 2>/dev/null | openssl x509 -noout -fingerprint -sha256`.
- Tools: `save_note` (mode `create`/`overwrite`/`append`, Ordner werden angelegt, `.md` wird ergänzt, Frontmatter mit `created` + `tags`, wenn der Text keins hat), `read_note`, `list_notes` (optional rekursiv), `recent_notes`, `search_notes` (siehe Suche), `move_note`.
- **Suche** (seit 02.10.2026): SQLite-Index `./data/index.db` (gehört 65534, darf gelöscht werden, wird beim Start neu aufgebaut). Notizen werden an Überschriften in Abschnitte (max. 1500 Zeichen) geteilt.
  - Abgleich beim Start und vor einer Suche, wenn der letzte älter als 60 s ist oder `save_note`/`move_note` lief. Nur neue/geänderte Notizen (ETag) werden geladen und neu berechnet, gelöschte entfernt.
  - Wortsuche: FTS5 über Pfad, Überschrift, Text (alle Ordner). Füllwörter und Wörter unter 3 Zeichen zählen nicht; eine Notiz muss mindestens die Hälfte der übrigen Wörter enthalten, Rang nach Anzahl, dann bm25.
  - Bedeutungssuche: `text-embedding-3-small` über LiteLLM (Key `OBSIDIAN_MCP_LITELLM_KEY` in `.env`, ohne Key nur Wortsuche). Treffer unter `MIN_SIMILARITY` (0.4) fallen weg – gemessen: Unpassendes 0.31–0.35, Passendes ab ~0.45.
  - `mode="auto"` führt beide per Reciprocal Rank Fusion zusammen; Ausgabe zeigt `Wort` / `Sinn 0.xx`.
  - **Datenschutz:** Ordner in `EMBED_EXCLUDE` (`Arbeit,Privat,Finanzen`) und Notizen mit `privat: true` im Frontmatter gehen nie an OpenAI. Wird eine Notiz nachträglich privat, wird ihr Vektor gelöscht.
  - Modell in LiteLLM: `text-embedding-3-small` → `openai/text-embedding-3-small`, Modus `embedding` (sonst trägt `update-models.py` es in OpenCode ein). Key `obsidian-mcp-service` im Team `mcp-services`, nur dieses Modell. Modellwechsel = einmal alles neu berechnen.
- **Kein Löschen.** Überschriebene Fassungen stehen in der Versionsgeschichte von Nextcloud. `create` nutzt `If-None-Match: *`, `append` `If-Match` (keine stillen Überschreibungen).
- Pfade: `..` abgelehnt, Zeichen `\ : * ? " < > | # ^ [ ]` werden entfernt. `.obsidian/`, `.trash/` und versteckte Ordner werden bei Suche/Liste übersprungen.
- `DEFAULT_FOLDER` (optional, `.env`): Zielordner, wenn `save_note` keinen Ordner bekommt. Standard seit 02.10.2026: `Inbox`.
- Ordnerstruktur steht in der Tool-Beschreibung von `save_note` (Projekte, KI, Wissen, Haus, Einkauf, Reisen, Arbeit, Privat, Finanzen, Archiv, sonst Inbox). So hält sich jeder Client daran (Hermes, OpenCode, Claude Code), ohne eigene Regel. Nach Änderung der Beschreibung: OpenCode-Server und Hermes neu starten, in Claude Code neue Sitzung.
- Zeitzone per `TZ` + `/etc/localtime` (sonst UTC im Frontmatter). `mem_limit` 256m (numpy + Vektoren).
- In LiteLLM: `obsidian_mcp`, URL `http://litellm-obsidian-mcp:8000/mcp`, keine Authentifizierung, am Team freigegeben.

## Uptime-Kuma-MCP (`uptime_kuma_mcp`)

Eigener Stack `vserv01:/opt/docker/stacks/uptime-kuma-mcp`, lokale Kopie in [`uptime-kuma-mcp/`](uptime-kuma-mcp/). Seit 29.09.2026. **Nur in OpenCode eingebunden**, nicht in Claude Code (Wunsch des Nutzers).

- Fertiges Image `davidfuchs/mcp-uptime-kuma:0.11.18` ([GitHub](https://github.com/DavidFuchs/mcp-uptime-kuma), MIT, Node 22 Alpine), kein eigener Code außer dem Patch der Anfragebremse (siehe unten). Start mit `-t streamable-http`, Port **3000** (nicht 8000), läuft als `1000:1000`, `read_only`.
- Uptime Kuma läuft als HA-Add-on, **Version 2** (Nachweis ohne Login: `GET /setup-database-info` gibt es nur in v2). Zugriff über Tailscale: `http://100.89.90.114:3001`. Öffentlich: `https://uptime.gizmonet.de`.
- `.env`: `UPTIME_KUMA_USERNAME`/`UPTIME_KUMA_PASSWORD` (keine 2FA; Uptime Kuma kennt nur einen Benutzer, deshalb keine eingeschränkten Rechte möglich), `MCP_AUTH_TOKEN` (zufällig, `openssl rand -hex 32`).
- **Token-Pflicht:** Ohne `MCP_AUTH_TOKEN` hätte jeder Container im Netz `litellm-caveman_default` Vollzugriff auf Uptime Kuma. LiteLLM schickt ihn (Auth **Bearer Token**). Ohne Token antwortet `/mcp` mit 401. `/health` ist absichtlich offen (Healthcheck per `wget`).
- 31 Tools, **alle aktiv** (Nutzer-Entscheidung 29.09.2026), inklusive create/update/delete für Monitore, Benachrichtigungen, Tags, Docker-Hosts und Statusseiten. Schutz nur über die Anweisung in OpenCodes `AGENTS.md`: Ändern und Löschen nur nach Bestätigung. Einschränken ließe sich das in LiteLLM → MCP Servers → `uptime_kuma_mcp` → Tools.
- Lesende Tools geben Geheimnisse als `***` aus.
- Startwarnung `ALLOWED_ORIGIN is "*"` betrifft nur Browser-Clients. Durch den Token ist sie unkritisch.
- In LiteLLM: `uptime_kuma_mcp`, URL `http://litellm-uptime-kuma-mcp:3000/mcp`, Bearer Token = `MCP_AUTH_TOKEN`, am Team freigegeben.
- **Anfragebremse gepatcht (30.09.2026):** Das Image begrenzt fest auf 100 Anfragen pro 15 Minuten pro IP (`express-rate-limit`, nicht per Env einstellbar). Alles kommt über LiteLLM, also von einer IP, und auch der Healthcheck zählt mit (15 pro 15 min). Folge: Hermes und OpenCode bekamen `429`. Deshalb baut `compose.yml` ein eigenes Image (`local/mcp-uptime-kuma:0.11.18-ratelimit`), das per `sed` in `dist/index.js` auf 5000 setzt. Findet `sed` die Zeile nach einem Update nicht mehr, bricht der Build ab.
- Für Berichte `getMonitorSummary` + `listMonitors` (enthält die 24-h-Uptime je Monitor) nehmen, nicht `getHeartbeats`: Das gilt nur für einen Monitor und reicht aus dem Cache höchstens 100 Prüfungen zurück (bei 60 s ca. 1,5 h).
- Update: Tag im `Dockerfile` (`FROM`) und `image:` in `compose.yml` erhöhen, `docker compose build --pull && docker compose up -d`. Neue Tools sind in LiteLLM erst einmal deaktiviert (siehe unten).

## Context7 (`context7_mcp`)

- Gehosteter MCP von Upstash, kein eigener Container. In LiteLLM: `context7_mcp`, URL `https://mcp.context7.com/mcp`, Streamable HTTP.
- Tools: `resolve-library-id` (Name → ID wie `/fastapi/fastapi`), `query-docs` (Doku-Ausschnitte zu einer Frage).
- Upstash sieht nur Bibliotheksnamen und Suchbegriffe. Ohne API-Key gelten strengere Rate-Limits (Key: context7.com/dashboard, in LiteLLM als Bearer Token).
- OpenCode: Eintrag in `data/config/opencode.json`, Anweisung in `data/config/AGENTS.md`.
- Claude Code (Windows): `claude mcp add --scope user --transport http context7 https://vserv01.tailf89473.ts.net:4000/context7_mcp/mcp` mit dem Header des Keys `claude-code-memory` (dessen MCP-Liste enthält `memory_mcp` und `context7_mcp`). `claude` steht nicht im PATH, die CLI liegt in der VS-Code-Erweiterung: `~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude.exe`. Anweisung in `~/.claude/CLAUDE.md`.

## Healthchecks

Seit 28.09.2026 haben alle eigenen Dienste einen Docker-Healthcheck. Docker startet `unhealthy` Container **nicht** neu, der Status ist nur zur Anzeige (Dockge, Dockhand, Beszel, `monitor_mcp`) und für `depends_on: condition: service_healthy`.

| Dienst | Prüfung |
|---|---|
| Alle MCPs (Python, Port 8000) | Socket auf 8000, `GET /mcp`, jede HTTP-Antwort zählt (MCP liefert 406). `curl` gibt es in `python:*-slim` nicht. |
| `litellm` | `python3` + `urllib` auf `/health/liveliness` (nur Prozess, nicht DB; `/health/readiness` würde bei DB-Ausfall 503 liefern). Kein `curl`/`wget` im Image. |
| `litellm-image-mcp-files` | `wget --spider http://127.0.0.1/` |
| `opencode-server` | `curl` ohne `-f`, damit 401 (Basic-Auth) als lebendig zählt |
| `media-browser` | Socket auf 8080, jede HTTP-Antwort |
| Postgres (Linkwarden, Open Archiver, Paperless) | `pg_isready -h 127.0.0.1` (braucht keinen gültigen Benutzer) |
| Valkey (Open Archiver, Paperless) | `valkey-cli ping`, `PONG` oder `NOAUTH` zählen, so bleibt das Passwort aus der Config |

Apps warten per `depends_on: condition: service_healthy` auf ihre Postgres/Valkey (Linkwarden, Open Archiver, Paperless-Webserver).

MCP-Block zum Kopieren (YAML: Python-Code in einfachen Anführungszeichen, sonst macht YAML aus `\r\n` echte Zeilenumbrüche):

```yaml
    healthcheck:
      test: ["CMD", "python", "-c", 'import socket,sys; s=socket.create_connection(("127.0.0.1",8000),5); s.sendall(b"GET /mcp HTTP/1.0\r\n\r\n"); sys.exit(0 if s.recv(12).startswith(b"HTTP/") else 1)']
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 20s
```

Ohne Healthcheck (bewusst): `video-mcp-worker`, `image-mcp-cleanup`, `monitor-docker-proxy`, Mailcow (eigener Watchdog, wird bei Updates überschrieben). Offen (Stufe 3, siehe Backlog): backrest, beszel, crowdsec, anubis, open-archiver, meilisearch, tika, gotenberg, headroom.

## Stolperstein: Fehlermeldungen im MCP-SDK 2.x

Mit `mcp==2.2.0` kommt nur ein `ToolError` (`from mcp.server.mcpserver.exceptions import ToolError`) mit Text beim Modell an. Jede andere Ausnahme (z. B. `ValueError`) gilt als Absturz: Das Modell sieht nur `Error executing tool <name>`. Erwartbare Fehler deshalb immer als `ToolError` werfen.

## Neuen MCP hinzufügen (Checkliste)

1. Eigener Stack unter `/opt/docker/stacks/<name>`, Netz `litellm-caveman_default` (extern), Container-Name `litellm-<name>`.
   Healthcheck-Block aus einem vorhandenen MCP übernehmen (siehe unten).
2. LiteLLM → MCP Servers: `<name>_mcp`, URL `http://litellm-<name>:8000/mcp`.
3. LiteLLM → **Team** freigeben, alle Tools. Am Key nichts eintragen.
4. OpenCode-Server: Eintrag in `data/config/opencode.json` unter `mcp`, dann `docker restart opencode-server`.
5. `docker exec -i opencode-server python3 - < check-tool-names.py`: keine Tool-Namen über 64 Zeichen.
6. `Update-OpenCodeLiteLLM.ps1`: Namen in `-McpServers` ergänzen (für lokal/Webtop).
7. Soll Claude Code (VS Code, Windows + Webtop) ihn auch nutzen: in `Update-OpenCodeLiteLLM.ps1` bei `-ClaudeMcpServers` ergänzen (`<Name in Claude Code> = '<name>_mcp'`), Skript laufen lassen, VS Code neu laden. Key `claude-code-memory` braucht die Freigabe. Stand: `memory`, `context7`, `obsidian` (Uptime Kuma bewusst nur OpenCode).

**Neues Tool in einem bestehenden MCP** (seit LiteLLM 1.102): Das Tool ist erst einmal **deaktiviert**. In LiteLLM unter MCP Servers → Server → Tools einschalten, dann unter Teams → Team → Server anhaken. Danach `check-tool-names.py` mit `SHOW=<server>` und `docker restart opencode-server`.

#!/usr/bin/env python3
"""Prüft, ob es eine neuere stabile LiteLLM-Version gibt als die auf vserv01.

Liegt in Hermes unter /config/.hermes/scripts/litellm_update.py.

  litellm_update.py            Cron-Modus: Ausgabe nur bei einer neuen Version,
                               je Version nur einmal (leere Ausgabe = Hermes schweigt)
  litellm_update.py --always   Stand immer ausgeben (für den Skill /litellm_update)
  litellm_update.py --notes    zusätzlich die Release Notes der neuesten Version (gekürzt)

Laufende Version: info.version aus /openapi.json (ohne Key abrufbar).
Neueste Version: höchster Tag vX.Y.Z der GitHub-Releases ohne prerelease/draft,
gleiche Regel wie update-litellm.sh (Backports wie v1.101.4 erscheinen nach v1.103.x).
"""
import json
import os
import re
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

LITELLM_URL = os.environ.get("LITELLM_URL", "http://100.105.233.113:4001").rstrip("/")
RELEASES_API = "https://api.github.com/repos/BerriAI/litellm/releases?per_page=50"
RELEASE_PAGE = "https://github.com/BerriAI/litellm/releases/tag/"
STATE = Path(__file__).with_name("litellm_update.state.json")
FAIL_ALERT = 3      # Cron: erst nach so vielen Fehlschlägen in Folge melden
NOTES_CHARS = 3500
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def get(url: str, limit: int = 0) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "hermes-litellm-update",
                                               "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read(limit) if limit else r.read()


def running_version() -> str:
    # openapi.json ist ~1,6 MB, info steht am Anfang
    head = get(f"{LITELLM_URL}/openapi.json", 256 * 1024).decode("utf-8", "replace")
    m = re.search(r'"info"\s*:\s*\{.*?"version"\s*:\s*"([^"]+)"', head, re.S)
    if not m:
        raise ValueError("Version nicht in openapi.json gefunden")
    return "v" + m.group(1).lstrip("v")


def vkey(tag: str):
    m = STABLE.match(tag)
    return tuple(int(x) for x in m.groups()) if m else None


def stable_releases() -> list:
    rel = [r for r in json.loads(get(RELEASES_API))
           if not r.get("prerelease") and not r.get("draft") and vkey(r.get("tag_name", ""))]
    return sorted(rel, key=lambda r: vkey(r["tag_name"]), reverse=True)


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_state(st: dict) -> None:
    try:
        STATE.write_text(json.dumps(st), encoding="utf-8")
    except OSError:
        pass


def date_de(iso: str) -> str:
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).strftime("%d.%m.%Y")
    except ValueError:
        return "?"


def short_notes(body: str) -> str:
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    # Ohne cosign-Anleitung und Danksagungen, das ist in jeder Release gleich
    body = re.sub(r"^## (Verify Docker Image Signature|New Contributors).*?(?=^## |\Z)", "",
                  body, flags=re.S | re.M).strip()
    if len(body) > NOTES_CHARS:
        body = body[:NOTES_CHARS].rsplit("\n", 1)[0] + "\n… (gekürzt)"
    return body or "(keine Release Notes)"


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    always = "--always" in sys.argv or "--notes" in sys.argv
    notes = "--notes" in sys.argv
    st = load_state()

    try:
        current = running_version()
        releases = stable_releases()
    except Exception as e:  # Netz, GitHub-Rate-Limit, LiteLLM down ...
        if always:
            print(f"⚠️ LiteLLM-Update-Prüfung fehlgeschlagen: {e}")
            return 0
        st["fails"] = st.get("fails", 0) + 1
        save_state(st)
        print(f"Fehler {st['fails']}: {e}", file=sys.stderr)
        if st["fails"] == FAIL_ALERT:
            print(f"⚠️ **LiteLLM-Update-Prüfung** schlägt seit {FAIL_ALERT} Läufen fehl: {e}")
        return 0
    st["fails"] = 0

    if not releases:
        save_state(st)
        if always:
            print("⚠️ Keine stabilen LiteLLM-Releases auf GitHub gefunden.")
        return 0

    cur = vkey(current) or (0,)
    newer = [r for r in releases if vkey(r["tag_name"]) > cur]
    latest = releases[0]
    tag = latest["tag_name"]

    if not newer:
        save_state(st)
        if always:
            print(f"✅ **LiteLLM** ist aktuell: {current} (neueste stabile: {tag} vom {date_de(latest['published_at'])})")
        return 0

    # Cron: jede neue Version nur einmal melden
    if not always and st.get("announced") == tag:
        save_state(st)
        return 0

    lines = [
        "🆕 **LiteLLM-Update verfügbar**",
        f"Läuft: {current}",
        f"Neu: {tag} vom {date_de(latest['published_at'])}",
    ]
    if len(newer) > 1:
        lines.append("Dazwischen: " + ", ".join(r["tag_name"] for r in reversed(newer[1:])))
    lines += [
        f"Notes: {RELEASE_PAGE}{tag}",
        "Update als root auf vserv01: `update-litellm -n`, dann `update-litellm`",
    ]
    if notes:
        lines += ["", f"--- Release Notes {tag} ---", short_notes(latest.get("body", ""))]
    print("\n".join(lines))
    st["announced"] = tag
    save_state(st)
    return 0


if __name__ == "__main__":
    sys.exit(main())

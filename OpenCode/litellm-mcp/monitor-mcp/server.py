import asyncio
import datetime
import hashlib
import json
import os
import re
import time
from typing import Optional

import httpx
import psutil
from mcp.server.mcpserver import MCPServer

# Nur lesend: Docker nur über den Socket-Proxy (GET), Host-Daten aus der Datei des
# server-status.timer. Von `docker inspect` werden nur Zustandsfelder gelesen, nie Env.
DOCKER_URL = os.environ.get("DOCKER_URL", "http://docker-proxy:2375").rstrip("/")
STATUS_FILE = os.environ.get("STATUS_FILE", "/host-status/status.json")
IMAGE_CACHE_SECONDS = int(os.environ.get("IMAGE_CACHE_HOURS", "6")) * 3600
# Images, deren Version ein Projekt selbst festlegt (z. B. Meilisearch in Open Archiver):
# keine Hinweise auf neuere Versions-Tags, Digest-Prüfung bleibt
IMAGE_IGNORE = [s.strip() for s in os.environ.get("IMAGE_IGNORE", "").split(",") if s.strip()]
STATUS_MAX_AGE = 30 * 60
STATS_CACHE_SECONDS = 20
# OpenCode bricht Tool-Aufrufe nach 60 s ab
TOOL_WAIT = 40
HEALTH_IMAGE_WAIT = 15

WARN_RAM = 85
WARN_SWAP = 80
WARN_DISK = 85
# Backups laufen täglich oder öfter; älter = ein Lauf ist ausgefallen
BACKUP_MAX_AGE = float(os.environ.get("BACKUP_MAX_AGE_HOURS", "26")) * 3600
# Warnung, wenn nur noch dieser Anteil der Laufzeit übrig ist. Short-Lived (6,7 Tage):
# ab 2,2 Tagen; 90-Tage-Zertifikat: ab 30 Tagen. Erneuert wird bei ~1/2, also ist dann
# mindestens eine Erneuerung ausgefallen.
CERT_WARN_FRACTION = 1 / 3
WARN_DOCKER_RECLAIM = float(os.environ.get("WARN_DOCKER_RECLAIM_GB", "20")) * 1e9

mcp = MCPServer(
    "Server-Monitor",
    instructions=(
        "Read-only monitoring of the user's Debian root server vserv01, which "
        "runs OpenCode, LiteLLM and many other Docker stacks. Start with "
        "health_check for a summary. server_overview shows CPU, RAM, swap, "
        "disks and whether a reboot is needed; container_stats lists "
        "containers (or stacks) by RAM or CPU; failed_services lists failed "
        "systemd units, unhealthy or crashed containers and journal errors; "
        "apt_updates lists pending Debian package updates; image_updates "
        "compares running Docker images with their registries; crowdsec_status "
        "shows CrowdSec bans, alerts and bouncer health; maintenance_status "
        "shows backups, TLS certificates and Docker disk usage. Nothing can be "
        "changed through this server: when updates, restarts or reboots are "
        "needed, tell the user which commands to run as root."
    ),
)

_docker = httpx.AsyncClient(base_url=DOCKER_URL, timeout=30)
_registry = httpx.AsyncClient(timeout=15, follow_redirects=True)
_docker_sem = asyncio.Semaphore(12)


# ---------- Formatierung ----------

def fmt_bytes(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if abs(n) < 1024:
            return f"{n:.0f} {unit}" if unit in ("B", "KiB", "MiB") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def fmt_age(seconds: float) -> str:
    if seconds < 90:
        return f"{int(seconds)} s"
    if seconds < 90 * 60:
        return f"{int(seconds / 60)} min"
    if seconds < 48 * 3600:
        return f"{seconds / 3600:.1f} h"
    return f"{int(seconds / 86400)} Tagen"


def pct(used: float, total: float) -> float:
    return used / total * 100 if total else 0.0


def parse_docker_time(value: str) -> float:
    # "2026-09-27T12:01:00.123456789Z" -> Unix-Zeit
    if not value or value.startswith("0001-"):
        return 0.0
    try:
        dt = datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
        return dt.replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return 0.0


# ---------- Host ----------

def load_status() -> tuple[Optional[dict], str]:
    try:
        with open(STATUS_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None, f"Host-Daten fehlen ({STATUS_FILE}): server-status.timer auf dem Host läuft nicht."
    except (OSError, ValueError) as e:
        return None, f"Host-Daten nicht lesbar: {e}"
    age = time.time() - data.get("time", 0)
    note = ""
    if age > STATUS_MAX_AGE:
        note = f"Achtung: Host-Daten sind {fmt_age(age)} alt, server-status.timer prüfen."
    return data, note


def host_metrics() -> dict:
    # /proc/stat und /proc/meminfo zeigen im Container die Werte des Hosts
    return {
        "cpu": psutil.cpu_percent(interval=1),
        "load": os.getloadavg(),
        "cores": psutil.cpu_count() or 1,
        "mem": psutil.virtual_memory(),
        "swap": psutil.swap_memory(),
        "uptime": time.time() - psutil.boot_time(),
    }


def reboot_info(status: dict) -> tuple[bool, str]:
    k = status.get("kernel") or {}
    r = status.get("reboot") or {}
    reasons = []
    if k.get("newest") and k.get("running") and k["newest"] != k["running"]:
        reasons.append(f"neuer Kernel {k['newest']} installiert, läuft {k['running']}")
    if r.get("flag"):
        pkgs = ", ".join(r.get("packages") or [])
        reasons.append("reboot-required gesetzt" + (f" ({pkgs})" if pkgs else ""))
    return bool(reasons), "; ".join(reasons)


# ---------- Docker ----------

async def docker_get(path: str, params: Optional[dict] = None):
    try:
        async with _docker_sem:
            r = await _docker.get(path, params=params)
    except httpx.HTTPError as e:
        raise ValueError(f"Docker-Proxy nicht erreichbar ({e.__class__.__name__}).")
    if r.status_code == 404:
        return None
    if r.status_code == 403:
        raise ValueError(f"Docker-Proxy verweigert {path}.")
    r.raise_for_status()
    return r.json()


async def list_containers(include_stopped: bool = True) -> list:
    return await docker_get("/containers/json", {"all": "1" if include_stopped else "0"}) or []


def cname(c: dict) -> str:
    names = c.get("Names") or []
    return names[0].lstrip("/") if names else c["Id"][:12]


def cstack(c: dict) -> str:
    return (c.get("Labels") or {}).get("com.docker.compose.project") or "(ohne Stack)"


def compose_info(c: dict) -> dict:
    """Ordner, Compose-Dateien und Dienstname aus den Labels, die docker compose setzt."""
    lab = c.get("Labels") or {}
    return {
        "dir": lab.get("com.docker.compose.project.working_dir", ""),
        "files": [f for f in lab.get("com.docker.compose.project.config_files", "").split(",") if f],
        "service": lab.get("com.docker.compose.service", ""),
    }


DEFAULT_COMPOSE = {"compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"}


def update_commands(results: list) -> list[str]:
    """Konkrete Befehle je Stack-Ordner, nur für die betroffenen Dienste."""
    stacks: dict = {}
    for r in results:
        if r["status"] != "update" and not r["stale"]:
            continue
        for ci in r.get("compose") or []:
            # dict statt set: Reihenfolge der Compose-Dateien zählt (erste = Basis)
            s = stacks.setdefault(ci["dir"], {"files": {}, "services": set()})
            s["files"].update(dict.fromkeys(ci["files"]))
            if ci["service"]:
                s["services"].add(ci["service"])
    cmds = []
    for d, s in sorted(stacks.items()):
        if not d:
            cmds.append("Container ohne Compose-Stack: Image pullen und Container neu erstellen")
        elif "mailcow" in d:
            # Mailcow pinnt seine Images selbst und aktualisiert nur über das eigene Skript
            cmds.append(f"cd {d} && ./update.sh --check   (meldet es ein Update: ./update.sh)")
        else:
            names = {f.rsplit("/", 1)[-1] for f in s["files"]}
            # Mehrere oder abweichende Compose-Dateien (z. B. litellm-caveman) explizit angeben
            fs = "" if len(names) <= 1 and names <= DEFAULT_COMPOSE else \
                "".join(f" -f {f.rsplit('/', 1)[-1]}" for f in s["files"])
            svc = " ".join(sorted(s["services"]))
            cmds.append(f"cd {d} && docker compose{fs} pull {svc} && docker compose{fs} up -d {svc}")
    return cmds


_stats_cache = {"time": 0.0, "data": []}


async def container_stat(c: dict) -> Optional[dict]:
    s = await docker_get(f"/containers/{c['Id']}/stats", {"stream": "false"})
    if not s:
        return None
    mem = s.get("memory_stats") or {}
    st = mem.get("stats") or {}
    used = mem.get("usage", 0) - st.get("inactive_file", st.get("total_inactive_file", 0))
    cpu, pre = s.get("cpu_stats") or {}, s.get("precpu_stats") or {}
    cpu_delta = (cpu.get("cpu_usage") or {}).get("total_usage", 0) - (pre.get("cpu_usage") or {}).get("total_usage", 0)
    sys_delta = cpu.get("system_cpu_usage", 0) - pre.get("system_cpu_usage", 0)
    online = cpu.get("online_cpus") or 1
    cpu_pct = cpu_delta / sys_delta * online * 100 if sys_delta > 0 and cpu_delta > 0 else 0.0
    return {
        "name": cname(c),
        "stack": cstack(c),
        "mem": max(used, 0),
        "limit": mem.get("limit", 0),
        "cpu": cpu_pct,
    }


async def all_stats() -> list:
    if time.time() - _stats_cache["time"] > STATS_CACHE_SECONDS:
        running = await list_containers(False)
        results = await asyncio.gather(*(container_stat(c) for c in running), return_exceptions=True)
        _stats_cache["data"] = [r for r in results if isinstance(r, dict)]
        _stats_cache["time"] = time.time()
    return _stats_cache["data"]


async def container_states() -> list:
    containers = await list_containers(True)

    async def inspect(c: dict) -> dict:
        d = await docker_get(f"/containers/{c['Id']}/json") or {}
        st = d.get("State") or {}
        # Nur Zustandsfelder übernehmen, Config/Env bleiben unberührt
        return {
            "name": cname(c),
            "stack": cstack(c),
            "state": st.get("Status") or c.get("State", ""),
            "health": (st.get("Health") or {}).get("Status", ""),
            "exit": st.get("ExitCode", 0),
            "oom": st.get("OOMKilled", False),
            "restarts": d.get("RestartCount", 0),
            "started": parse_docker_time(st.get("StartedAt", "")),
            "finished": parse_docker_time(st.get("FinishedAt", "")),
            "policy": ((d.get("HostConfig") or {}).get("RestartPolicy") or {}).get("Name", ""),
        }

    return await asyncio.gather(*(inspect(c) for c in containers))


def container_problems(states: list) -> list[str]:
    now = time.time()
    out = []
    for s in sorted(states, key=lambda s: s["name"]):
        issues = []
        if s["health"] == "unhealthy":
            issues.append("unhealthy")
        if s["state"] == "restarting":
            issues.append("startet ständig neu")
        if s["state"] == "dead":
            issues.append("dead")
        if s["state"] == "exited" and s["exit"] != 0:
            when = f" vor {fmt_age(now - s['finished'])}" if s["finished"] else ""
            issues.append(f"beendet mit Exit-Code {s['exit']}{when}")
        if s["oom"]:
            issues.append("wegen RAM-Mangel beendet (OOM)")
        if s["restarts"] and s["state"] == "running":
            issues.append(f"{s['restarts']} automatische Neustarts, läuft seit {fmt_age(now - s['started'])}")
        if issues:
            out.append(f"{s['name']} [{s['stack']}]: " + ", ".join(issues))
    return out


# ---------- Registries (Image-Updates) ----------

MANIFEST_ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
])
_tokens: dict = {}


def parse_ref(ref: str) -> Optional[tuple[str, str, str]]:
    if not ref or "@" in ref or ref.startswith("sha256:"):
        return None
    first, _, rest = ref.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        registry, path = first, rest
    else:
        registry, path = "registry-1.docker.io", ref
    if registry in ("docker.io", "index.docker.io"):
        registry = "registry-1.docker.io"
    name, tag = path, "latest"
    if ":" in path.rsplit("/", 1)[-1]:
        name, tag = path.rsplit(":", 1)
    if registry == "registry-1.docker.io" and "/" not in name:
        name = "library/" + name
    return registry, name, tag


async def registry_request(registry: str, repo: str, path: str, method: str = "GET",
                           headers: Optional[dict] = None, params: Optional[dict] = None) -> httpx.Response:
    url = f"https://{registry}/v2/{repo}/{path}"
    h = dict(headers or {})
    if _tokens.get((registry, repo)):
        h["Authorization"] = f"Bearer {_tokens[(registry, repo)]}"
    r = await _registry.request(method, url, headers=h, params=params)
    auth = r.headers.get("www-authenticate", "")
    if r.status_code == 401 and auth.lower().startswith("bearer"):
        # Anonymes Token holen (Docker Hub, ghcr, ... für öffentliche Images)
        fields = dict(re.findall(r'(\w+)="([^"]*)"', auth))
        q = {k: fields[k] for k in ("service", "scope") if k in fields}
        q.setdefault("scope", f"repository:{repo}:pull")
        t = await _registry.get(fields.get("realm", ""), params=q)
        if t.status_code == 200:
            body = t.json()
            _tokens[(registry, repo)] = body.get("token") or body.get("access_token")
            h["Authorization"] = f"Bearer {_tokens[(registry, repo)]}"
            r = await _registry.request(method, url, headers=h, params=params)
    return r


class NotInRegistry(ValueError):
    """Image ist lokal gebaut oder privat (Registry kennt es nicht oder verlangt Anmeldung)."""


def registry_error(r: httpx.Response) -> ValueError:
    if r.status_code in (401, 403, 404):
        return NotInRegistry(f"HTTP {r.status_code}")
    if r.status_code == 429:
        return ValueError("Rate-Limit der Registry")
    return ValueError(f"Registry antwortet HTTP {r.status_code}")


async def remote_digest(registry: str, repo: str, tag: str) -> str:
    h = {"Accept": MANIFEST_ACCEPT}
    r = await registry_request(registry, repo, f"manifests/{tag}", "HEAD", h)
    digest = r.headers.get("docker-content-digest")
    if r.status_code == 200 and digest:
        return digest
    if r.status_code in (200, 405):
        r = await registry_request(registry, repo, f"manifests/{tag}", "GET", h)
        if r.status_code == 200:
            return r.headers.get("docker-content-digest") or "sha256:" + hashlib.sha256(r.content).hexdigest()
    raise registry_error(r)


VERSION_RE = re.compile(r"^(v?)(\d+(?:\.\d+)+)(?:-(\d+))?(.*)$")


def version_key(tag: str):
    # Nur Tags mit mind. zwei Zahlen (1.2, v1.101.2, 1.30.4-1); Form muss gleich bleiben
    m = VERSION_RE.match(tag)
    if not m:
        return None
    nums = tuple(int(x) for x in m.group(2).split("."))
    build = (int(m.group(3)),) if m.group(3) else ()
    shape = (m.group(1), len(nums), bool(build), m.group(4))
    return shape, nums + build


async def newer_tags(registry: str, repo: str, tag: str) -> tuple[Optional[str], Optional[str]]:
    """(neueste Version gleicher Hauptversion, neueste neue Hauptversion)"""
    key = version_key(tag)
    if not key:
        return None, None
    same = major = None
    params: Optional[dict] = {"n": "1000"}
    for _ in range(10):
        r = await registry_request(registry, repo, "tags/list", params=params)
        if r.status_code != 200:
            break
        for t in r.json().get("tags") or []:
            k = version_key(t)
            if not k or k[0] != key[0] or k[1] <= key[1]:
                continue
            if k[1][0] == key[1][0]:
                if same is None or k[1] > same[1]:
                    same = (t, k[1])
            elif major is None or k[1] > major[1]:
                major = (t, k[1])
        m = re.search(r"<([^>]+)>", r.headers.get("link", ""))
        if not m:
            break
        params = dict(httpx.URL(m.group(1)).params)
    return (same[0] if same else None), (major[0] if major else None)


def is_ignored(ref: str) -> bool:
    # "getmeili/meilisearch" trifft alle Tags, "mariadb:10.11" nur diesen, "ghcr.io/mailcow/*" alle darunter
    name = ref.rsplit(":", 1)[0] if ":" in ref.rsplit("/", 1)[-1] else ref
    name = name.removeprefix("docker.io/")
    for i in IMAGE_IGNORE:
        if i.endswith("*") and name.startswith(i[:-1]):
            return True
        if ref == i or name == i:
            return True
    return False


async def check_images(with_versions: bool) -> list:
    running = await list_containers(False)

    async def image_name(c: dict) -> str:
        # Wurde der Tag neu gepullt, zeigt die Liste nur noch "sha256:…". Der ursprüngliche
        # Name steht in Config.Image (sonst nichts aus Config lesen, dort liegen auch Env-Secrets).
        ref = c.get("Image", "")
        if ref.startswith("sha256:"):
            d = await docker_get(f"/containers/{c['Id']}/json") or {}
            ref = (d.get("Config") or {}).get("Image") or ref
        return ref

    names = await asyncio.gather(*(image_name(c) for c in running))
    by_ref: dict = {}
    for c, ref in zip(running, names):
        by_ref.setdefault(ref, []).append(c)
    sem = asyncio.Semaphore(6)

    async def check(ref: str, cs: list) -> dict:
        res = {"ref": ref, "containers": sorted(cname(c) for c in cs), "stale": [], "newer": None, "major": None,
               "compose": [compose_info(c) for c in cs]}
        parsed = parse_ref(ref)
        tagged = await docker_get(f"/images/{ref}/json") if parsed else None
        base = tagged or await docker_get(f"/images/{cs[0]['ImageID']}/json") or {}
        digests = {d.split("@", 1)[1] for d in base.get("RepoDigests") or [] if "@" in d}
        if tagged:
            res["stale"] = sorted(cname(c) for c in cs if c.get("ImageID") != tagged.get("Id"))
        if not parsed:
            res["status"] = "skip"
            return res
        if not digests:
            res["status"] = "local"
            return res
        try:
            async with sem:
                remote = await remote_digest(*parsed)
                if with_versions and not is_ignored(ref):
                    res["newer"], res["major"] = await newer_tags(*parsed)
        except NotInRegistry:
            res["status"] = "local"
            return res
        except (httpx.HTTPError, ValueError) as e:
            res["status"] = "error"
            res["note"] = str(e) or e.__class__.__name__
            return res
        res["status"] = "current" if remote in digests else "update"
        return res

    return await asyncio.gather(*(check(ref, cs) for ref, cs in by_ref.items()))


_images = {"time": 0.0, "results": None, "versions": False, "task": None, "error": ""}


async def ensure_image_check(force: bool, with_versions: bool, wait: float) -> bool:
    """Startet die Prüfung im Hintergrund, wartet höchstens `wait` Sekunden. True = fertig."""
    st = _images
    fresh = (st["results"] is not None
             and time.time() - st["time"] < IMAGE_CACHE_SECONDS
             and (st["versions"] or not with_versions))
    task = st["task"]
    if (task is None or task.done()) and (force or not fresh):
        async def run():
            try:
                st["results"] = await check_images(with_versions)
                st.update(time=time.time(), versions=with_versions, error="")
            except Exception as e:  # im Hintergrund, sonst geht der Fehler verloren
                st["error"] = str(e) or e.__class__.__name__
        task = st["task"] = asyncio.create_task(run())
    if task is not None and not task.done():
        try:
            await asyncio.wait_for(asyncio.shield(task), wait)
        except asyncio.TimeoutError:
            return False
    return True


# ---------- CrowdSec ----------

BOUNCER_STALE = 10 * 60


def crowdsec_checks(status: dict) -> tuple[list[str], list[str]]:
    """(Warnungen, Hinweise) für CrowdSec, bezogen auf den Zeitpunkt der Datenerfassung."""
    cs = status.get("crowdsec")
    if not cs:
        return [], []
    if cs.get("error"):
        return [f"CrowdSec: {cs['error']}"], []
    now = status.get("time", time.time())
    warn, info = [], []
    fresh_types = {b["type"] for b in cs.get("bouncers") or []
                   if not b.get("revoked") and now - parse_docker_time(b.get("last_pull", "")) < BOUNCER_STALE}
    names = [b["name"] for b in cs.get("bouncers") or []]
    for b in cs.get("bouncers") or []:
        if b.get("revoked"):
            continue
        age = now - parse_docker_time(b.get("last_pull", ""))
        if age < BOUNCER_STALE:
            continue
        # "name@ip" legt CrowdSec automatisch an, wenn derselbe API-Key von einer neuen IP
        # abruft. Abrufe zählen dann dort, der Stammeintrag bleibt stehen und darf nicht
        # gelöscht werden (cscli löscht die @-Einträge mit, der Bouncer verliert den Zugang).
        if any(n.startswith(b["name"] + "@") for n in names):
            continue
        if b["type"] in fresh_types:
            info.append(f"Bouncer {b['name']} ruft seit {fmt_age(age)} nicht ab, ein anderer {b['type']} ist aktiv "
                        f"(vor dem Löschen prüfen, ob noch ein Dienst diesen Key nutzt)")
        else:
            warn.append(f"Bouncer {b['name']} ({b['type']}) ruft nicht mehr ab, letzter Abruf vor {fmt_age(age)}")
    for m in cs.get("machines") or []:
        age = now - parse_docker_time(m.get("last_heartbeat", ""))
        if age > BOUNCER_STALE:
            warn.append(f"CrowdSec-Maschine {m['name']} meldet sich nicht, letzter Heartbeat vor {fmt_age(age)}")
    for h in (cs.get("hub") or {}).get("issues") or []:
        info.append(f"Hub: {h['kind']} {h['name']} – {h['status']}")
    return warn, info


# ---------- Wartung: Backups, Zertifikate, Docker-Speicher ----------

def fmt_until(seconds: float) -> str:
    return f"{seconds / 86400:.1f} Tage" if seconds >= 86400 else f"{seconds / 3600:.0f} h"


def backup_lines(status: dict) -> tuple[list[str], list[str]]:
    """(Warnungen, Zeilen je Backup)"""
    data = status.get("backups")
    if data is None:
        return ["Backups: keine Daten (server-status-collect zu alt)"], []
    if isinstance(data, dict):
        return [f"Backups: {data.get('error', '?')}"], []
    now = status.get("time", time.time())
    uptime = time.time() - psutil.boot_time()
    warn, lines = [], []
    for b in data:
        name = b["timer"].removesuffix(".timer")
        age = now - b["last"] if b["last"] else None
        when = f"vor {fmt_age(age)}" if age is not None else "seit Neustart nicht gelaufen"
        state = "läuft gerade" if b["running"] else (b["result"] or "?")
        lines.append(f"  {name}: {when}, {state}")
        if not b["timer_active"]:
            warn.append(f"Backup {name}: Timer ist nicht aktiv")
        elif b["result"] and b["result"] != "success":
            warn.append(f"Backup {name} fehlgeschlagen ({b['result']}, Exit {b['exit']}), "
                        f"Log: journalctl -u {b['unit']} -n 50")
        elif age is not None and age > BACKUP_MAX_AGE and not b["running"]:
            warn.append(f"Backup {name} zuletzt vor {fmt_age(age)}")
        elif age is None and uptime > BACKUP_MAX_AGE:
            warn.append(f"Backup {name} lief seit dem Neustart vor {fmt_age(uptime)} nicht")
    return warn, lines


def cert_lines(status: dict) -> tuple[list[str], list[str]]:
    data = status.get("certificates")
    if data is None:
        return ["Zertifikate: keine Daten (server-status-collect zu alt)"], []
    if isinstance(data, dict):
        return [f"Zertifikate: {data.get('error', '?')}"], []
    now = time.time()
    warn, lines, unused = [], [], []
    for c in data:
        if c.get("error"):
            warn.append(f"Zertifikate {c['source']}: {c['error']}")
            continue
        names = ", ".join(c["names"][:3]) + (f" (+{len(c['names']) - 3})" if len(c["names"]) > 3 else "")
        if c.get("served") is False:
            unused.append(names)
            continue
        life = c["not_after"] - c["not_before"]
        left = c["not_after"] - now
        lines.append(f"  {names} [{c['source']}]: noch {fmt_until(left)} (Laufzeit {fmt_until(life)})")
        if left <= 0:
            warn.append(f"Zertifikat {names} [{c['source']}] ist ABGELAUFEN")
        elif left <= life * CERT_WARN_FRACTION:
            warn.append(f"Zertifikat {names} [{c['source']}]: nur noch {fmt_until(left)} gültig "
                        f"(Laufzeit {fmt_until(life)}), Erneuerung prüfen")
    if unused:
        lines.append("  Nicht ausgeliefert (Datei ohne Proxy-Host?): " + ", ".join(unused))
    return warn, lines


def docker_disk_lines(status: dict) -> tuple[list[str], list[str]]:
    data = status.get("docker_disk")
    if data is None:
        return ["Docker-Speicher: keine Daten (server-status-collect zu alt)"], []
    if data.get("error"):
        return [f"Docker-Speicher: {data['error']}"], []
    labels = {"Images": "Images", "Containers": "Container", "Local Volumes": "Volumes", "Build Cache": "Build-Cache"}
    lines = []
    for key, label in labels.items():
        d = data.get(key)
        if d:
            lines.append(f"  {label}: {d['count']} ({d['active']} aktiv), {fmt_bytes(d['size'])}, "
                         f"freigebbar {fmt_bytes(d['reclaimable'])}")
    reclaim = sum((data.get(k) or {}).get("reclaimable", 0) for k in ("Images", "Build Cache"))
    warn = []
    if reclaim > WARN_DOCKER_RECLAIM:
        warn.append(f"Docker: {fmt_bytes(reclaim)} freigebbar (Images + Build-Cache)")
    return warn, lines


def maintenance_checks(status: dict) -> dict:
    """{Bereich: (Warnungen, [OK-Text, Detailzeilen ...])} für health_check und maintenance_status."""
    out = {}
    w, lines = backup_lines(status)
    out["backups"] = (w, [f"{len(lines)} Backups gelaufen und erfolgreich"] + lines)
    w, lines = cert_lines(status)
    out["certs"] = (w, ["Zertifikate gültig"] + lines)
    w, lines = docker_disk_lines(status)
    out["docker"] = (w, ["Docker-Speicher ok"] + lines)
    return out


# ---------- Tools ----------

@mcp.tool()
async def server_overview() -> str:
    """CPU usage and load, RAM, swap, disks, uptime, reboot status and the biggest host processes by RAM."""
    m = await asyncio.to_thread(host_metrics)
    status, note = load_status()
    mem, swap = m["mem"], m["swap"]
    lines = []
    if status:
        lines.append(f"{status.get('hostname', '?')} · {status.get('os', '')} · Kernel {(status.get('kernel') or {}).get('running', '?')}")
    lines.append(f"Läuft seit {fmt_age(m['uptime'])}")
    l1, l5, l15 = m["load"]
    lines.append(f"CPU: {m['cpu']:.0f} % ({m['cores']} Kerne), Last {l1:.2f} / {l5:.2f} / {l15:.2f} (1/5/15 min)")
    used = mem.total - mem.available
    lines.append(f"RAM: {fmt_bytes(used)} von {fmt_bytes(mem.total)} belegt ({pct(used, mem.total):.0f} %), "
                 f"{fmt_bytes(mem.available)} verfügbar, davon Cache {fmt_bytes(getattr(mem, 'cached', 0))}")
    lines.append(f"Swap: {fmt_bytes(swap.used)} von {fmt_bytes(swap.total)} ({swap.percent:.0f} %)")
    if status:
        lines.append("Platten:")
        for d in status.get("disks") or []:
            lines.append(f"  {d['mount']}: {fmt_bytes(d['used'])} von {fmt_bytes(d['size'])} "
                         f"({pct(d['used'], d['size']):.0f} %), frei {fmt_bytes(d['avail'])}")
        needed, why = reboot_info(status)
        lines.append("Neustart nötig: " + (f"ja – {why}" if needed else "nein"))
        procs = status.get("top_processes") or []
        if procs:
            lines.append("Größte Prozesse nach RAM (Host, inkl. Container):")
            for p in procs:
                count = f" ×{p['count']}" if p["count"] > 1 else ""
                lines.append(f"  {p['name']}{count}: {fmt_bytes(p['rss'])}")
    if note:
        lines.append(note)
    return "\n".join(lines)


@mcp.tool()
async def container_stats(sort_by: str = "ram", limit: int = 15, group_by_stack: bool = False,
                          name_filter: str = "") -> str:
    """List running containers by RAM or CPU usage.

    sort_by: "ram" or "cpu". group_by_stack=True sums up containers per compose stack
    (e.g. mailcow). name_filter matches container or stack names (substring).
    CPU is shown Docker-style: 100 % = one full core.
    """
    if sort_by not in ("ram", "cpu"):
        raise ValueError('sort_by muss "ram" oder "cpu" sein.')
    stats = await all_stats()
    total_mem = psutil.virtual_memory().total
    if name_filter:
        f = name_filter.lower()
        stats = [s for s in stats if f in s["name"].lower() or f in s["stack"].lower()]
    if not stats:
        return "Keine laufenden Container gefunden."
    key = "mem" if sort_by == "ram" else "cpu"
    sum_mem = sum(s["mem"] for s in stats)
    sum_cpu = sum(s["cpu"] for s in stats)
    head = (f"{len(stats)} Container laufen, zusammen {fmt_bytes(sum_mem)} RAM "
            f"({pct(sum_mem, total_mem):.0f} % des Hosts), CPU {sum_cpu:.0f} % (100 % = 1 Kern).")
    lines = [head]
    limit = max(1, min(limit, 100))
    if group_by_stack:
        groups: dict = {}
        for s in stats:
            g = groups.setdefault(s["stack"], {"mem": 0, "cpu": 0.0, "n": 0})
            g["mem"] += s["mem"]
            g["cpu"] += s["cpu"]
            g["n"] += 1
        lines.append("Stack | Container | RAM | CPU")
        for name, g in sorted(groups.items(), key=lambda kv: -kv[1][key])[:limit]:
            lines.append(f"{name} | {g['n']} | {fmt_bytes(g['mem'])} | {g['cpu']:.1f} %")
    else:
        lines.append("Container [Stack] | RAM (Limit) | CPU")
        for s in sorted(stats, key=lambda s: -s[key])[:limit]:
            lim = "kein Limit" if not s["limit"] or s["limit"] >= total_mem * 0.95 else f"Limit {fmt_bytes(s['limit'])}"
            lines.append(f"{s['name']} [{s['stack']}] | {fmt_bytes(s['mem'])} ({lim}) | {s['cpu']:.1f} %")
    return "\n".join(lines)


@mcp.tool()
async def failed_services() -> str:
    """Failed systemd units, unhealthy/crashed/restarting containers and the most frequent journal errors of the last 24 h."""
    status, note = load_status()
    states = await container_states()
    lines = []
    if status:
        units = status.get("failed_units") or []
        lines.append(f"systemd: {len(units)} fehlgeschlagen" if units else "systemd: keine fehlgeschlagenen Dienste")
        for u in units:
            detail = ", ".join(x for x in (u.get("result"), u.get("since")) if x)
            lines.append(f"  {u['unit']} ({u.get('description', '')}): {u.get('sub', '')}" + (f" – {detail}" if detail else ""))
    problems = container_problems(states)
    running = sum(1 for s in states if s["state"] == "running")
    lines.append(f"Container: {running} von {len(states)} laufen, "
                 + (f"{len(problems)} mit Problemen" if problems else "keine Probleme"))
    lines.extend(f"  {p}" for p in problems)
    stopped = sorted(s["name"] for s in states if s["state"] == "exited" and s["exit"] == 0)
    if stopped:
        lines.append("Normal gestoppt (Exit 0): " + ", ".join(stopped))
    if status:
        errors = status.get("journal_errors") or []
        lines.append("Journal-Fehler (24 h): " + ("keine" if not errors else f"{sum(e['count'] for e in errors)} in den häufigsten Quellen"))
        now = time.time()
        for e in errors:
            when = f", zuletzt vor {fmt_age(now - e['time'])}" if e.get("time") else ""
            lines.append(f"  {e['source']}: {e['count']}×{when} – {e['last']}")
    if note:
        lines.append(note)
    return "\n".join(lines)


@mcp.tool()
async def apt_updates(security_only: bool = False) -> str:
    """Pending Debian package updates (from the host's apt lists, refreshed by apt-daily.timer)."""
    status, note = load_status()
    if not status:
        return note
    apt = status.get("apt") or {}
    pkgs = apt.get("updates") or []
    sec = [p for p in pkgs if p.get("security")]
    lists_age = time.time() - apt.get("lists_time", 0) if apt.get("lists_time") else None
    lines = [f"{len(pkgs)} Updates verfügbar, davon {len(sec)} Sicherheitsupdates."]
    if lists_age is not None:
        lines.append(f"Paketlisten zuletzt aktualisiert vor {fmt_age(lists_age)}.")
    shown = sec if security_only else sorted(pkgs, key=lambda p: (not p.get("security"), p["name"]))
    for p in shown[:150]:
        flag = " [Sicherheit]" if p.get("security") else ""
        lines.append(f"  {p['name']}: {p['old']} → {p['new']}{flag}")
    if len(shown) > 150:
        lines.append(f"  … und {len(shown) - 150} weitere")
    if pkgs:
        lines.append("Installieren (als root): apt update && apt full-upgrade")
    needed, why = reboot_info(status)
    if needed:
        lines.append(f"Neustart nötig: {why}")
    if note:
        lines.append(note)
    return "\n".join(lines)


def format_images(results: list, checked_at: float, with_versions: bool) -> str:
    groups: dict = {}
    for r in results:
        groups.setdefault(r["status"], []).append(r)
    stale = [r for r in results if r["stale"]]
    newer = [r for r in results if r.get("newer")]
    major = [r for r in results if r.get("major")]
    lines = [f"{len(results)} Images geprüft vor {fmt_age(time.time() - checked_at)}."]
    if groups.get("update"):
        lines.append("Neues Image in der Registry (pull nötig):")
        for r in groups["update"]:
            lines.append(f"  {r['ref']} → {', '.join(r['containers'])}")
    if stale:
        lines.append("Neueres Image schon gepullt, Container aber noch auf dem alten (neu erstellen):")
        for r in stale:
            lines.append(f"  {r['ref']} → {', '.join(r['stale'])}")
    if newer:
        lines.append("Neuere Version verfügbar (Tag in compose.yml ändern):")
        for r in newer:
            lines.append(f"  {r['ref']} → {r['newer']}")
    if major:
        lines.append("Neue Hauptversion verfügbar (Changelog/Migration prüfen, v. a. bei Datenbanken):")
        for r in major:
            lines.append(f"  {r['ref']} → {r['major']}")
    lines.append(f"Aktuell: {len(groups.get('current', []))}")
    if groups.get("local"):
        lines.append(f"Lokal gebaut oder privat (nicht prüfbar): {len(groups['local'])}")
    if groups.get("skip"):
        lines.append("Per Digest gepinnt oder ohne Namen: " + ", ".join(sorted(r["ref"] for r in groups["skip"])))
    if groups.get("error"):
        lines.append("Nicht prüfbar:")
        for r in groups["error"]:
            lines.append(f"  {r['ref']}: {r.get('note', '')}")
    if not with_versions:
        lines.append("Neuere Versions-Tags wurden nicht gesucht (check_new_versions=True).")
    else:
        ignored = sorted(r["ref"] for r in results if is_ignored(r["ref"]))
        if ignored:
            lines.append("Versions-Tags nicht gesucht (IMAGE_IGNORE, Version legt das Projekt fest): " + ", ".join(ignored))
    cmds = update_commands(results)
    if cmds:
        lines.append("Aktualisieren (als root):")
        lines.extend(f"  {c}" for c in cmds)
    return "\n".join(lines)


@mcp.tool()
async def image_updates(refresh: bool = False, check_new_versions: bool = False) -> str:
    """Check whether newer Docker images exist for the running containers.

    Compares the local image digest with the registry (Docker Hub, ghcr.io, ...).
    Results are cached for a few hours; refresh=True forces a new check.
    check_new_versions=True also looks for higher version tags (e.g. v1.101.2 → v1.102.0)
    for containers pinned to a version; new major versions are listed separately. A long check continues in the background;
    call again after a minute if it is not finished yet.
    """
    done = await ensure_image_check(refresh, check_new_versions, TOOL_WAIT)
    if not done:
        return "Prüfung läuft noch im Hintergrund. In etwa einer Minute erneut image_updates aufrufen."
    if _images["error"] and _images["results"] is None:
        return f"Prüfung fehlgeschlagen: {_images['error']}"
    text = format_images(_images["results"], _images["time"], _images["versions"])
    if _images["error"]:
        text += f"\nLetzte Prüfung fehlgeschlagen ({_images['error']}), gezeigt wird der vorige Stand."
    return text


@mcp.tool()
async def crowdsec_status(limit: int = 15) -> str:
    """CrowdSec intrusion prevention: active local bans, blocklists, alerts of the last 24 h,
    bouncer and machine health, hub items needing updates. limit = number of recent bans shown."""
    status, note = load_status()
    if not status:
        return note
    cs = status.get("crowdsec")
    if not cs:
        return "Keine CrowdSec-Daten. server-status-collect auf dem Host ist zu alt (ohne CrowdSec-Teil)."
    if cs.get("error"):
        return f"CrowdSec: {cs['error']}" + (f"\n{note}" if note else "")
    now = status.get("time", time.time())
    lines = [f"CrowdSec {cs.get('version', '?')} · Stand vor {fmt_age(time.time() - now)}"]

    origins = cs.get("decisions_by_origin") or {}
    lists = {"CAPI": "Community-Blockliste", "lists": "Zusatzlisten", "crowdsec": "lokal erkannt", "cscli": "manuell"}
    # Lokale Sperren zählt die Liste unten, hier nur die Blocklisten
    parts = [f"{lists.get(o, o)} {n}" for o, n in sorted(origins.items(), key=lambda kv: -kv[1])
             if o not in ("crowdsec", "cscli")]
    lines.append(f"Aktive Sperren: {cs.get('decisions_total', 0)} lokal erkannt"
                 + (f", dazu Blocklisten: {', '.join(parts)}" if parts else ""))
    for d in (cs.get("decisions") or [])[:max(1, min(limit, 50))]:
        who = " ".join(x for x in (d.get("cn"), d.get("as")) if x)
        lines.append(f"  {d['ip']} ({who or '?'}) – {d['scenario']} – {d['type']}, noch {d['duration']}")

    a = cs.get("alerts_24h") or {}
    lines.append(f"Alerts 24 h: {a.get('count', 0)}")
    if a.get("scenarios"):
        lines.append("  Szenarien: " + ", ".join(f"{k} {v}×" for k, v in a["scenarios"].items()))
    if a.get("countries"):
        lines.append("  Länder: " + ", ".join(f"{k} {v}" for k, v in a["countries"].items()))
    if a.get("ips"):
        lines.append("  Häufigste IPs: " + ", ".join(f"{k} {v}×" for k, v in a["ips"].items()))

    lines.append("Bouncer:")
    for b in cs.get("bouncers") or []:
        age = now - parse_docker_time(b.get("last_pull", ""))
        if b.get("revoked"):
            state = "widerrufen"
        elif any(n.startswith(b["name"] + "@") for n in (x["name"] for x in cs.get("bouncers") or [])):
            state = "Stammeintrag des API-Keys, Abrufe zählen beim @-Eintrag"
        else:
            state = f"letzter Abruf vor {fmt_age(age)}"
        lines.append(f"  {b['name']} ({b['type']}): {state}")
    lines.append("Maschinen:")
    for m in cs.get("machines") or []:
        lines.append(f"  {m['name']}: Heartbeat vor {fmt_age(now - parse_docker_time(m.get('last_heartbeat', '')))}")
    hub = cs.get("hub") or {}
    lines.append(f"Hub: {hub.get('enabled', 0)} aktive Einträge, "
                 + (f"{len(hub['issues'])} mit Update/verändert" if hub.get("issues") else "alle aktuell"))

    warn, info = crowdsec_checks(status)
    if warn:
        lines.append("WARNUNGEN:")
        lines.extend(f"  [!] {w}" for w in warn)
    if info:
        lines.append("Hinweise:")
        lines.extend(f"  {i}" for i in info)
    if note:
        lines.append(note)
    return "\n".join(lines)


@mcp.tool()
async def maintenance_status(section: str = "all") -> str:
    """Backups (systemd backup/dump timers: last run, result), TLS certificates of NPMplus and
    mailcow (days left; certificates are short-lived, ~6.7 days) and Docker disk usage
    (images, volumes, build cache, reclaimable space).
    section: "all", "backups", "certs" or "docker"."""
    status, note = load_status()
    if not status:
        return note
    checks = maintenance_checks(status)
    if section != "all" and section not in checks:
        raise ValueError('section muss "all", "backups", "certs" oder "docker" sein.')
    titles = {"backups": "Backups", "certs": "Zertifikate", "docker": "Docker-Speicher"}
    lines = [f"Stand vor {fmt_age(time.time() - status.get('time', 0))}"]
    for key, (warn, ok) in checks.items():
        if section not in ("all", key):
            continue
        lines.append(f"{titles[key]}:")
        lines.extend(f"  [!] {w}" for w in warn)
        lines.extend(ok[1:])
        if key == "docker" and warn:
            lines.append("  Aufräumen (als root): docker builder prune -f; docker image prune -f "
                         "(nur unbenutzte; -a löscht auch Images gestoppter Stacks)")
    if note:
        lines.append(note)
    return "\n".join(lines)


@mcp.tool()
async def health_check() -> str:
    """Short overall health summary of the server: warnings first, then what is OK."""
    m_task = asyncio.to_thread(host_metrics)
    m, states, stats = await asyncio.gather(m_task, container_states(), all_stats())
    status, note = load_status()
    images_done = await ensure_image_check(False, False, HEALTH_IMAGE_WAIT)
    warn, ok = [], []

    l1 = m["load"][0]
    (warn if l1 > m["cores"] else ok).append(f"CPU {m['cpu']:.0f} %, Last {l1:.2f} bei {m['cores']} Kernen")
    mem = m["mem"]
    used_pct = pct(mem.total - mem.available, mem.total)
    top = sorted(stats, key=lambda s: -s["mem"])[:3]
    top_txt = ", ".join(f"{s['name']} {fmt_bytes(s['mem'])}" for s in top)
    (warn if used_pct > WARN_RAM else ok).append(f"RAM {used_pct:.0f} % belegt (größte: {top_txt})")
    swap = m["swap"]
    if swap.total:
        (warn if swap.percent > WARN_SWAP else ok).append(f"Swap {swap.percent:.0f} %")

    if status:
        for d in status.get("disks") or []:
            p = pct(d["used"], d["size"])
            if p > WARN_DISK:
                warn.append(f"Platte {d['mount']} zu {p:.0f} % voll")
        if not any(pct(d["used"], d["size"]) > WARN_DISK for d in status.get("disks") or []):
            ok.append("Platten unter {} %".format(WARN_DISK))
        units = status.get("failed_units") or []
        if units:
            warn.append("systemd fehlgeschlagen: " + ", ".join(u["unit"] for u in units))
        else:
            ok.append("keine fehlgeschlagenen systemd-Dienste")
        pkgs = (status.get("apt") or {}).get("updates") or []
        sec = sum(1 for p in pkgs if p.get("security"))
        if sec:
            warn.append(f"{sec} Sicherheitsupdates (von {len(pkgs)} APT-Updates)")
        elif pkgs:
            warn.append(f"{len(pkgs)} APT-Updates verfügbar")
        else:
            ok.append("APT aktuell")
        needed, why = reboot_info(status)
        if needed:
            warn.append(f"Neustart nötig: {why}")
        errors = status.get("journal_errors") or []
        if errors:
            ok.append("Journal-Fehler 24 h: " + ", ".join(f"{e['source']} {e['count']}×" for e in errors[:3]))
        cs_warn, _ = crowdsec_checks(status)
        warn.extend(cs_warn)
        cs = status.get("crowdsec") or {}
        if cs and not cs.get("error") and not cs_warn:
            ok.append(f"CrowdSec: {cs.get('decisions_total', 0)} lokale Sperren, "
                      f"{(cs.get('alerts_24h') or {}).get('count', 0)} Alerts in 24 h, Bouncer aktiv")
    else:
        warn.append(note)

    problems = container_problems(states)
    if problems:
        warn.append(f"{len(problems)} Container mit Problemen: " + "; ".join(problems))
    else:
        running = sum(1 for s in states if s["state"] == "running")
        ok.append(f"{running} Container laufen ohne Probleme")

    if status:
        for key, (w, o) in maintenance_checks(status).items():
            warn.extend(w)
            if not w and o:
                ok.append(o[0])

    if images_done and _images["results"] is not None:
        res = _images["results"]
        upd = [r["ref"] for r in res if r["status"] == "update"]
        stale = [r["ref"] for r in res if r["stale"]]
        age = fmt_age(time.time() - _images["time"])
        if upd or stale:
            warn.append(f"Image-Updates (Stand vor {age}): " + ", ".join(sorted(set(upd + stale))))
        else:
            ok.append(f"Docker-Images aktuell (Stand vor {age})")
    else:
        ok.append("Image-Prüfung läuft noch – später image_updates aufrufen")

    if status and note:
        warn.append(note)
    lines = ["WARNUNGEN:" if warn else "Keine Warnungen."]
    lines.extend(f"  [!] {w}" for w in warn)
    lines.append("OK:")
    lines.extend(f"  [ok] {o}" for o in ok)
    return "\n".join(lines)


if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=8000,
        stateless_http=True,
        json_response=True,
    )

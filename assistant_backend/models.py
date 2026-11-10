"""Model files on the phone: which ones this phone needs, and downloading them.

docs/AI_MODEL_DOWNLOAD.md, docs/AI_CURRENT_RULES.md section 7 (2026-11-10). The
App does not carry the models; the first time the assistant opens, the App asks
the user and, only after "下載", this module downloads them into the models
folder the native side reads (Android: Android/data/<package>/files/models,
iOS: Documents/models). One implementation for both phones, standard library
only, so it is tested on the computer.

- The manifest (models.json, next to this module on the phone, assets/assistant
  in the repository) lists every file: its name on the phone, size, SHA-256,
  which part it belongs to and where it comes from.
- Parts: "core" (language gate, speech, e5 and the FAQ index, Vietnamese; the
  assistant works once they are there), "decision" (the decision model), and
  "taiwanese" (optional). Which files a phone gets depends on its total memory
  (tier) and platform.
- A file is present when it has the manifest's size (files pushed with adb or
  devicectl count). A download goes to <name>.part, resumes with an HTTP Range
  request, and is renamed only after its size and SHA-256 match.
- Sources: TOWNPASS_MODEL_BASE_URL (one mirror for every file: the city's
  server, or a test server on the computer), else the file's own url (the
  original authors' Hugging Face), else the manifest's team_url + path. A file
  without a source is not offered.

Only file requests leave the phone; nothing about the user is sent.
"""
from __future__ import annotations

import hashlib
import http.client
import json
import os
import pathlib
import shutil
import threading
import time
import urllib.error
import urllib.request

PARTS = ("core", "decision", "taiwanese")
# Total memory (MB, as the phone reports it) for each tier (rules section 7).
FULL_RAM_MB = 10_500      # 12 GB phones report ~11,200-11,700 MB
STANDARD_RAM_MB = 7_000   # 8 GB phones report ~7,300-7,700 MB
# Phones under STANDARD_RAM_MB get only the core files (no decision model),
# allowed only while the no-model evaluation opens no wrong page.
LITE_ALLOWED = True
# Free space kept on the phone after a download.
SPARE_BYTES = 300 << 20
CHUNK = 1 << 20
ATTEMPTS = 4
TIMEOUT_S = 30


class DownloadError(Exception):
    """A download that stopped: code is what the App shows (models_error_<code>)."""

    def __init__(self, code, detail=""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code


class _Paused(Exception):
    pass


def default_manifest_path():
    here = pathlib.Path(__file__).resolve().parent
    packaged = here / "models.json"  # the phone: packaged next to the modules
    return packaged if packaged.exists() else here.parent / "assets" / "assistant" / "models.json"


def load_manifest(path=None):
    with open(path or default_manifest_path(), encoding="utf-8") as f:
        manifest = json.load(f)
    if manifest.get("version") != 1 or not isinstance(manifest.get("files"), list):
        raise ValueError("unknown models.json version")
    return manifest


def tier(ram_mb):
    """"full", "standard" or "lite" for a phone with ram_mb of total memory
    (unknown counts as full: the computer, or a native side that did not say)."""
    if ram_mb is None or ram_mb >= FULL_RAM_MB:
        return "full"
    return "standard" if ram_mb >= STANDARD_RAM_MB else "lite"


class Downloads:
    """The models one phone needs and their download (one at a time).

    on_file(entry) is called after each file is in place (device_main starts the
    server that uses it); opener is urllib.request.urlopen (tests pass a fake).
    """

    def __init__(self, models_dir, platform="android", ram_mb=None, decision_model="ministral",
                 manifest=None, base_url=None, on_file=None, opener=None, free_bytes=None):
        self.dir = pathlib.Path(models_dir)
        self.platform = platform
        self.ram_mb = ram_mb
        self.decision_model = decision_model
        self.manifest = manifest or load_manifest()
        self.base_url = (base_url or "").rstrip("/") or None
        self.on_file = on_file
        self.opener = opener or urllib.request.urlopen
        self._free_bytes = free_bytes or (lambda: shutil.disk_usage(self.dir).free)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.thread = None
        self.state = "idle"      # idle, downloading, paused, error, done
        self.error = None        # DownloadError.code of the last failure
        self.current = None      # id of the file being downloaded
        self.plan = []           # entries of the current or last download
        self.dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------- which files

    @property
    def tier(self):
        return tier(self.ram_mb)

    def parts_for_phone(self):
        """The parts this phone can have: no decision model on lite phones."""
        return [p for p in PARTS if not (p == "decision" and self.tier == "lite")]

    def wanted(self, part):
        """This phone's files of part (platform, tier and decision model)."""
        return [e for e in self.manifest["files"] if e["part"] == part
                and self.platform in e.get("platforms", (self.platform,))
                and self.tier in e.get("tiers", (self.tier,))
                and e.get("decision_model", self.decision_model) == self.decision_model]

    def path(self, entry):
        return self.dir / entry["name"]

    def present(self, entry):
        """In place with the manifest's size (a pushed file counts; a .part does not)."""
        try:
            return self.path(entry).stat().st_size == entry["size"]
        except OSError:
            return False

    def ready(self, part):
        files = self.wanted(part)
        return bool(files) and all(self.present(e) for e in files)

    def source(self, entry):
        if self.base_url:
            return f"{self.base_url}/{entry.get('path', entry['name'])}"
        if entry.get("url"):
            return entry["url"]
        team = (self.manifest.get("team_url") or "").rstrip("/")
        return f"{team}/{entry.get('path', entry['name'])}" if team else None

    def _have(self, entry):
        if self.present(entry):
            return entry["size"]
        try:
            return min(entry["size"], (self.path(entry).with_name(self.path(entry).name + ".part")).stat().st_size)
        except OSError:
            return 0

    # ----------------------------------------------------------------- status

    def status(self):
        """What the App shows: per part its size, what is missing and whether it
        can be downloaded here; the running download's progress."""
        parts = {}
        for part in PARTS:
            files = self.wanted(part)
            missing = [e for e in files if not self.present(e)]
            parts[part] = {
                "allowed": part in self.parts_for_phone() and bool(files),
                "ready": bool(files) and not missing,
                "bytes": sum(e["size"] for e in files),
                "missing_bytes": sum(e["size"] for e in missing),
                "downloadable": all(self.source(e) for e in missing),
            }
        with self.lock:
            plan, state, error, current = list(self.plan), self.state, self.error, self.current
        total = sum(e["size"] for e in plan)
        try:
            free = self._free_bytes()
        except OSError:
            free = None
        lite = self.tier == "lite"
        return {
            "managed": True,
            "platform": self.platform,
            "tier": self.tier,
            "ram_mb": self.ram_mb,
            # "unavailable": a lite phone while the lite mode is not allowed.
            "assistant": "unavailable" if lite and not LITE_ALLOWED else "lite" if lite else "full",
            "free_bytes": free,
            "parts": parts,
            "state": state,
            "error": error,
            "current": current,
            "progress": {"done": sum(self._have(e) for e in plan), "total": total},
        }

    # ---------------------------------------------------------------- actions

    def start(self, parts=None, base_url=None):
        """Download the missing files of parts (default: core, then the decision
        model when the phone has one). A running download keeps going.
        base_url: a mirror for every file (the App's ASSISTANT_MODEL_BASE_URL);
        https, or plain http to this phone (a test server through adb reverse).
        Every file is still checked against the manifest's SHA-256."""
        if base_url:
            if not valid_base_url(base_url):
                raise ValueError("model mirror must be https (or http on 127.0.0.1)")
            self.base_url = base_url.rstrip("/")
        parts = list(parts or [p for p in ("core", "decision") if p in self.parts_for_phone()])
        if any(p not in self.parts_for_phone() for p in parts):
            raise ValueError("part not available on this phone")
        with self.lock:
            if self.thread and self.thread.is_alive():
                return False
            plan = [e for p in PARTS if p in parts for e in self.wanted(p) if not self.present(e)]
            self.plan, self.error, self.current = plan, None, None
            if not plan:
                self.state = "done"
                return False
            if not all(self.source(e) for e in plan):
                self.state, self.error = "error", "source"
                return False
            needed = sum(e["size"] - self._have(e) for e in plan) + SPARE_BYTES
            try:
                if self._free_bytes() < needed:
                    self.state, self.error = "error", "storage"
                    return False
            except OSError:
                pass
            self.stop.clear()
            self.state = "downloading"
            self.thread = threading.Thread(target=self._run, args=(plan,), name="model-download", daemon=True)
            self.thread.start()
            return True

    def cancel(self):
        """Pause: the .part files stay, the next start resumes them."""
        self.stop.set()
        thread = self.thread
        if thread:
            thread.join(10)

    def delete(self, parts=None):
        """Remove this phone's files of parts (default all) and their .part files."""
        self.cancel()
        for part in parts or PARTS:
            if part not in PARTS:
                raise ValueError("unknown part")
            for entry in self.wanted(part):
                for path in (self.path(entry), self.path(entry).with_name(self.path(entry).name + ".part")):
                    try:
                        path.unlink()
                    except OSError:
                        pass
        with self.lock:
            self.state, self.error, self.current, self.plan = "idle", None, None, []

    def wait(self, timeout=None):
        thread = self.thread
        if thread:
            thread.join(timeout)

    # -------------------------------------------------------------- the worker

    def _run(self, plan):
        try:
            for entry in plan:
                if self.stop.is_set():
                    raise _Paused()
                if self.present(entry):
                    continue
                with self.lock:
                    self.current = entry["id"]
                self._fetch(entry)
                print(f"models: {entry['id']} in place ({entry['size'] >> 20} MB)", flush=True)
                if self.on_file:
                    try:
                        self.on_file(entry)
                    except Exception as exc:  # the file stays; the next launch starts its server
                        print(f"models: starting the server for {entry['id']} failed ({type(exc).__name__})",
                              flush=True)
            state, error = "done", None
        except _Paused:
            state, error = "paused", None
        except DownloadError as exc:
            print(f"models: download stopped ({exc})", flush=True)
            state, error = "error", exc.code
        with self.lock:
            self.state, self.error, self.current = state, error, None

    def _fetch(self, entry):
        target = self.path(entry)
        part = target.with_name(target.name + ".part")
        target.parent.mkdir(parents=True, exist_ok=True)
        url = self.source(entry)
        size = entry["size"]
        for attempt in range(ATTEMPTS):
            have = part.stat().st_size if part.exists() else 0
            if have > size:
                part.unlink()
                have = 0
            if have == size:
                break
            headers = {"User-Agent": "TownPass-Assistant/1"}
            if have:
                headers["Range"] = f"bytes={have}-"
            try:
                with self.opener(urllib.request.Request(url, headers=headers), timeout=TIMEOUT_S) as response:
                    code = response.getcode() if hasattr(response, "getcode") else response.status
                    if have and code != 206:
                        have = 0  # the server sent the whole file
                    with open(part, "ab" if have else "wb") as out:
                        while True:
                            if self.stop.is_set():
                                raise _Paused()
                            block = response.read(CHUNK)
                            if not block:
                                break
                            out.write(block)
                            have += len(block)
                            if have > size:
                                break
                if part.stat().st_size >= size:
                    break
            except _Paused:
                raise
            except urllib.error.HTTPError as exc:
                if exc.code == 416 and part.exists() and part.stat().st_size == size:
                    break
                if exc.code in (401, 403, 404):
                    raise DownloadError("source", f"{entry['id']} HTTP {exc.code}") from exc
                if attempt == ATTEMPTS - 1:
                    raise DownloadError("network", f"{entry['id']} HTTP {exc.code}") from exc
            except (OSError, http.client.HTTPException) as exc:  # IncompleteRead: the connection dropped
                if self.stop.is_set():
                    raise _Paused() from exc
                if attempt == ATTEMPTS - 1:
                    raise DownloadError("network", f"{entry['id']} {type(exc).__name__}") from exc
            if self.stop.wait(min(2 ** attempt, 8)):
                raise _Paused()
        if not part.exists() or part.stat().st_size != size:
            if part.exists():
                part.unlink()
            raise DownloadError("network", f"{entry['id']} incomplete")
        if sha256(part, self.stop) != entry["sha256"]:
            part.unlink()
            raise DownloadError("checksum", entry["id"])
        os.replace(part, target)


def valid_base_url(url):
    import urllib.parse
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme == "https" and parsed.hostname:
        return True
    return parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")


def sha256(path, stop=None):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 << 20), b""):
            if stop is not None and stop.is_set():
                raise _Paused()
            digest.update(block)
    return digest.hexdigest()

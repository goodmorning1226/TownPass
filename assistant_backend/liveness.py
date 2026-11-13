"""Which local model servers answer, so that a request never waits long for a dead one.

docs/AI_CURRENT_RULES.md section 5 (2026-11-13). The phone's model servers load after
the App starts, so a request that arrives first waits for them (up to 60-75 s:
asr_server.READY_WAIT_S, server.MODEL_READY_WAIT_S, classifier.WAIT_S). That long
wait is right only while a server has never answered. Once it has, a refused
connection means it stopped (iOS reclaimed its socket while the App was suspended,
or it exited) and a timeout means it hangs: waiting 75 s per call then made a turn
"look for the answer" for minutes after the phone was unlocked (iPhone, 2026-11-13).

- wait_s(url, startup): how long a call may wait for url to come up: startup until
  it has answered once, AFTER_READY_WAIT_S after that.
- hung(url): a server that answered before and now accepts without answering GET
  /health within PROBE_S (stopped, e.g. SIGSTOP): reported failed, and the call gives
  up in seconds instead of its full timeout (the classifier's 10 s, Android emulator
  test 2026-11-13). Asked before each classifier, e5 and whisper call. A busy server
  still answers /health, so a slow reply keeps its usual timeout: a bounded read
  timeout (3 s) cut off real classifier decisions that took 6 s on a loaded emulator.
- down(url): url failed recently (HOLD_S); callers skip it at once and use their
  usual "no answer" path (list the candidates, "please say it again", no FAQ).
- answered(url) / failed(url): what callers report. failed() also tells the
  watchers (device_main.Restarter asks the App to start the server again).

Standard library only; one instance per process (the functions below).
"""
from __future__ import annotations

import threading
import time
import urllib.parse

# After a server has answered once: how long a call waits for it to come back
# (the native side re-binds a reclaimed socket within ~1 s, a small model reloads in
# under a second), and how long a failed server is then skipped.
AFTER_READY_WAIT_S = 3.0
HOLD_S = 30.0
# probe(): how long GET /health may take before a server that answered before counts
# as hung (a long speech decode would otherwise cost the full request timeout first).
PROBE_S = 2.0

_lock = threading.Lock()
_answered: set[str] = set()
_down_until: dict[str, float] = {}
_watchers: list = []
clock = time.monotonic


def key(url):
    """scheme://host:port of url (the server, whatever the path)."""
    parts = urllib.parse.urlsplit(url)
    return f"{parts.scheme}://{parts.hostname}:{parts.port or 80}"


def wait_s(url, startup):
    """How long a call to url may wait for the server to come up."""
    with _lock:
        return min(startup, AFTER_READY_WAIT_S) if key(url) in _answered else startup


def has_answered(url):
    with _lock:
        return key(url) in _answered


def down(url):
    """Whether url failed within the last HOLD_S seconds."""
    with _lock:
        until = _down_until.get(key(url))
        if until is None:
            return False
        if clock() >= until:
            del _down_until[key(url)]
            return False
        return True


def answered(url):
    with _lock:
        _answered.add(key(url))
        _down_until.pop(key(url), None)


def failed(url, reason="failed", hold=True):
    """url did not answer (refused after its wait, or timed out): skip it for HOLD_S
    and tell the watchers once per hold. hold=False (reason "error": it answers, but
    with a server error, e.g. whisper.cpp's GPU backend broke): only tell the watchers,
    so that the server is restarted; requests keep using it."""
    with _lock:
        name = key(url)
        fresh = clock() >= _down_until.get(name, 0.0)
        if hold:
            _down_until[name] = clock() + HOLD_S
        watchers = list(_watchers) if fresh else []
    for watcher in watchers:
        try:
            watcher(name, reason)
        except Exception:  # a watcher must never break the request
            pass


def watch(callback):
    """callback(server_key, reason) after a server stops answering."""
    with _lock:
        _watchers.append(callback)


def probe(url, timeout=None):
    """Whether the server at url answers GET /health within timeout (any status counts;
    a refused connection too: the caller's short wait handles that). False only when
    it accepts and does not answer: a server that hangs. llama-server and whisper-server
    answer /health while they compute, so a busy server is not taken for a hung one."""
    import urllib.error
    import urllib.request
    try:
        with urllib.request.urlopen(key(url) + "/health", timeout=PROBE_S if timeout is None else timeout):
            return True
    except urllib.error.HTTPError:
        return True
    except OSError as exc:
        return not is_timeout(exc)


def hung(url):
    """Whether url answered before and does not answer GET /health now (probe); it is
    then reported (failed: skipped for HOLD_S, the App asked to restart it). False for a
    server that never answered: it may still be loading, and its caller waits as before."""
    if not has_answered(url) or probe(url):
        return False
    failed(url, "timeout")
    return True


def is_timeout(exc):
    """Whether exc is a socket timeout (the server accepted but did not answer)."""
    import socket
    import urllib.error
    if isinstance(exc, urllib.error.URLError):
        exc = exc.reason
    return isinstance(exc, (TimeoutError, socket.timeout))


def reset():
    """Forget everything (tests)."""
    with _lock:
        _answered.clear()
        _down_until.clear()
        _watchers.clear()

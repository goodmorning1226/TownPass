"""Serves the model files from this computer as a download mirror, to test the App's
model download (docs/AI_MODEL_DOWNLOAD.md) without uploading anything.

Each manifest entry's path (assets/assistant/models.json) maps to the local file
scripts/build_model_manifest.py read it from. Range requests are supported, so a
paused or interrupted download resumes. Loopback only; reach it from an Android
phone through adb reverse:

  python -X utf8 scripts/serve_assistant_models.py            # port 8899
  adb -s <id> reverse tcp:8899 tcp:8899
  .\\scripts\\run_assistant_on_device.ps1 -DeviceId <id> -ModelBaseUrl http://127.0.0.1:8899
"""
import argparse
import http.server
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from build_model_manifest import FILES  # noqa: E402  (the same local paths)

ROOT = pathlib.Path(__file__).resolve().parent.parent


def routes():
    manifest = json.loads((ROOT / "assets" / "assistant" / "models.json").read_text(encoding="utf-8"))
    local = {file_id: path for file_id, _, _, path, _, _, _ in FILES}
    return {"/" + e["path"]: local[e["id"]] for e in manifest["files"] if e["id"] in local}


class Mirror(http.server.BaseHTTPRequestHandler):
    ROUTES = {}

    def do_GET(self):
        path = self.ROUTES.get(self.path)
        if not path or not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start = 0
        if self.headers.get("Range", "").startswith("bytes="):
            start = int(self.headers["Range"][6:].split("-")[0] or 0)
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(size - start))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            while block := f.read(1 << 20):
                try:
                    self.wfile.write(block)
                except OSError:  # the phone paused or dropped
                    return

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8899)
    args = parser.parse_args()
    Mirror.ROUTES = routes()
    for route, path in Mirror.ROUTES.items():
        print(f"{route} <- {path}{'' if os.path.isfile(path) else '  (missing)'}")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Mirror)
    print(f"serving on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

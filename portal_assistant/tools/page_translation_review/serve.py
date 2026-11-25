"""Serves a translation job to mlkit_review.dart on a phone or emulator and
saves what it sends back (development only; portal_assistant/docs/AI_PAGE_TRANSLATION.md).

    python -X utf8 portal_assistant/tools/page_translation_review/serve.py <job.json> <out.json> [port]

The job is {"languages": [...], "items": [{"text", "mode"}], "back": bool};
see mlkit_review.dart for the modes. The results so far arrive after every
language and are saved each time. Build one from extracted page texts with
portal_assistant/scripts/review_translations.py --job. Stops after the last language arrives. Only
listens on 127.0.0.1 (reach it from the device with adb reverse).
"""
import http.server
import json
import sys

job_path, out_path = sys.argv[1], sys.argv[2]
port = int(sys.argv[3]) if len(sys.argv) > 3 else 8897
job = open(job_path, "rb").read()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/job":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(job)))
        self.end_headers()
        self.wfile.write(job)

    def do_POST(self):
        if self.path != "/results":
            self.send_error(404)
            return
        try:
            data = json.loads(self.body().decode("utf-8"))
            # Every post holds all results so far (one per finished language).
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
        except Exception as error:  # reported to the device, server keeps going
            self.send_error(400, str(error)[:200])
            return
        self.send_response(204)
        self.end_headers()
        print(f"saved {len(data['results'])} results to {out_path}", flush=True)
        self.server.done = bool(data.get("done", True))

    def body(self):
        length = self.headers.get("Content-Length")
        if length is not None:
            return self.rfile.read(int(length))
        out = b""  # chunked transfer encoding
        while True:
            size = int(self.rfile.readline().split(b";")[0].strip(), 16)
            if size == 0:
                self.rfile.readline()
                return out
            out += self.rfile.read(size)
            self.rfile.readline()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", port), Handler)
server.done = False
print(f"serving {job_path} on 127.0.0.1:{port}", flush=True)
while not server.done:
    server.handle_request()

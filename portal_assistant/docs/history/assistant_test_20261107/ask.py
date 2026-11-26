"""Send one assistant turn the way the App does and print a compact JSON result.

python ask.py --port 8781 --session s1 "我要借書"
python ask.py --port 8781 --session s1 --resolution <id> --choice 2 ""
python ask.py --port 8781 --session s1 --context '{"page": {"type": "tab", "index": 0}}' "這是什麼"
"""
import argparse
import json
import sys
import urllib.error
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--session", default=None)
parser.add_argument("--resolution", default=None)
parser.add_argument("--choice", default=None)
parser.add_argument("--context", default=None, help="JSON object sent as the contract-3 context field")
parser.add_argument("text", nargs="?", default="")
args = parser.parse_args()

payload = {"text": args.text, "request_id": uuid.uuid4().hex[:24],
           "session_id": args.session or ("t-" + uuid.uuid4().hex[:12])}
if args.resolution:
    payload["resolution_id"] = args.resolution
if args.choice is not None:
    payload["choice_id"] = args.choice
if args.context:
    payload["context"] = json.loads(args.context)
body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
request = urllib.request.Request(f"http://127.0.0.1:{args.port}/v1/assistant/turns", data=body,
                                 headers={"Content-Type": "application/json", "Content-Length": str(len(body))})
try:
    with urllib.request.urlopen(request, timeout=600) as response:
        status, data = response.status, json.loads(response.read())
except urllib.error.HTTPError as exc:
    status, data = exc.code, json.loads(exc.read() or b"{}")
except OSError as exc:
    status, data = 0, {"error": str(exc)}

metrics = data.get("metrics") or {}
out = {"status": status, "session_id": payload["session_id"], "kind": data.get("kind"), "action": data.get("action"),
       "destination": data.get("destination"), "route": metrics.get("route"),
       "model_calls": metrics.get("model_calls"), "elapsed_ms": metrics.get("elapsed_ms"),
       "resolution_id": data.get("resolution_id"),
       "choices": [{"id": c.get("id"), "title": c.get("title"), "enabled": c.get("enabled")} for c in data.get("choices") or []],
       "language": data.get("language") or metrics.get("language"),
       "message": data.get("message") or data.get("error")}
sys.stdout.reconfigure(encoding="utf-8")
print(json.dumps(out, ensure_ascii=False))

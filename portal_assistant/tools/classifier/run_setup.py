"""One full evaluation of a setup, everything on this agent's own ports (8971-8975).

Usage: run_setup.py NAME SOURCE_DIR [--llm ministral|gemma|none] [--classifier] [--cpu-llm] [ENV=VALUE ...]
       [--classifier-model GGUF] [--e5-model GGUF] [--llm-model GGUF] [--work DIR]

- SOURCE_DIR is a repository checkout (new layout): snapshot SOURCE_DIR/portal_assistant/backend and
  SOURCE_DIR/portal_assistant/app/assets/assistant into <work>/results/NAME/snap/portal_assistant/
  (the same relative layout, so the backend finds its catalogue)
- e5 :8973 (CPU), classifier :8972 (CPU -t 4, when --classifier), decision LLM :8974
  (llama-server b12182 Vulkan -ngl 99, phone args -c 6144 -np 3 --cache-ram 0 --reasoning off;
  warmed with the three system prompts like device_main.warm_up), backend :8971 (TOWNPASS_TIMING_LOG=1)
- sets: dev, holdout (report only), i18n, i18n_send (--send-language), colloquial, foreign,
  cdev, creport, guides (eval_guides.py --end-to-end, dev cases), guides_holdout (report only)
- stops only the processes it started.

Executables and models (argument, else environment variable):
  TOWNPASS_LLAMA_SERVER      llama-server, CPU build (e5, classifier, --cpu-llm)
  TOWNPASS_LLAMA_SERVER_GPU  llama-server, Vulkan build (decision LLM without --cpu-llm)
  TOWNPASS_E5_GGUF           --e5-model, multilingual-e5-small q8_0
  TOWNPASS_CLASSIFIER_GGUF   --classifier-model (with --classifier). The backend's classifier.VERSION
                             follows classifier.MODEL_NAME (now v2): evaluating a v1 file needs
                             TOWNPASS_CLASSIFIER_VERSION=1 as an ENV=VALUE argument.
  TOWNPASS_MINISTRAL_GGUF / TOWNPASS_GEMMA_GGUF   --llm-model, per --llm
"""
import argparse
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cls_paths  # noqa: E402

BACKEND, CLS, E5_PORT, LLM = 8971, 8972, 8973, 8974
PHONE_ARGS = ["-c", "6144", "-np", "3", "--cache-ram", "0", "--reasoning", "off", "--no-webui"]


def get(url, payload=None, timeout=600):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def wait(url, deadline=600, check=lambda b: True):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            body = get(url, timeout=5)
            if check(body):
                return body
        except Exception:  # noqa: BLE001
            pass
        time.sleep(2)
    return None


def main():
    parser = argparse.ArgumentParser(description="One full evaluation of a setup (ports 8971-8975).")
    parser.add_argument("name", help="results/<name> in the work directory")
    parser.add_argument("source", help="repository checkout to snapshot (portal_assistant/backend + assets)")
    parser.add_argument("env", nargs="*", metavar="ENV=VALUE", help="extra environment for the backend")
    parser.add_argument("--llm", default="none", choices=["ministral", "gemma", "none"])
    parser.add_argument("--classifier", action="store_true", help="start the classifier server")
    parser.add_argument("--cpu-llm", action="store_true", help="run the decision LLM on the CPU build")
    parser.add_argument("--classifier-model", help=f"classifier GGUF (default ${cls_paths.CLASSIFIER_GGUF_ENV})")
    parser.add_argument("--e5-model", help=f"e5 GGUF (default ${cls_paths.E5_GGUF_ENV})")
    parser.add_argument("--llm-model", help="decision LLM GGUF (default $TOWNPASS_MINISTRAL_GGUF / $TOWNPASS_GEMMA_GGUF)")
    cls_paths.work_argument(parser)
    opts = parser.parse_intermixed_args()
    cls_paths.set_work(opts.work)
    work = cls_paths.work_dir()
    name, source = opts.name, pathlib.Path(opts.source)
    llm = opts.llm
    use_cls = opts.classifier
    cpu_llm = opts.cpu_llm
    extra = dict(kv.split("=", 1) for kv in opts.env if "=" in kv and not kv.startswith("--"))
    cpu = cls_paths.required(None, cls_paths.LLAMA_SERVER_ENV, "the llama-server executable (CPU build, b12182)")
    e5 = cls_paths.required(opts.e5_model, cls_paths.E5_GGUF_ENV, "the multilingual-e5-small q8_0 GGUF", "--e5-model")
    classifier_model = cls_paths.required(opts.classifier_model, cls_paths.CLASSIFIER_GGUF_ENV,
                                          "the classifier GGUF", "--classifier-model") if use_cls else None
    llm_model = vulkan = None
    if llm != "none":
        llm_model = cls_paths.required(opts.llm_model, cls_paths.LLM_GGUF_ENV[llm], f"the {llm} GGUF", "--llm-model")
        if not cpu_llm:
            vulkan = cls_paths.required(None, cls_paths.LLAMA_SERVER_GPU_ENV,
                                        "the llama-server executable (Vulkan build, b12182)")
    out = work / "results" / name
    for port in (BACKEND, CLS, E5_PORT, LLM):
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                raise SystemExit(f"port {port} already in use")
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    snap = out / "snap"
    shutil.copytree(source / "portal_assistant" / "backend", snap / "portal_assistant" / "backend",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(source / "portal_assistant" / "app" / "assets" / "assistant",
                    snap / "portal_assistant" / "app" / "assets" / "assistant")
    backend_dir = snap / "portal_assistant" / "backend"
    env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8", "TOWNPASS_TIMING_LOG": "1",
           "TOWNPASS_MODEL_TIMEOUT": "300", "TOWNPASS_FAQ_EMBED_URL": f"http://127.0.0.1:{E5_PORT}",
           "TOWNPASS_SEMANTIC_CACHE": str(work / "cache" / "semantic"),
           "TOWNPASS_CATALOG_CACHE": str(work / "cache" / "library_catalog.json"),
           "TOWNPASS_CLASSIFIER_URL": f"http://127.0.0.1:{CLS}", **extra}
    if llm != "none":
        env.update(TOWNPASS_MODEL_API="openai", TOWNPASS_MODEL_URL=f"http://127.0.0.1:{LLM}",
                   TOWNPASS_DECISION_MODEL=llm)
    procs = []
    info = {"name": name, "source": str(source), "llm": llm, "classifier": use_cls, "env": extra}
    try:
        procs.append(subprocess.Popen([cpu, "-m", e5, "--embedding", "--pooling", "mean", "--host", "127.0.0.1",
                                       "--port", str(E5_PORT), "-c", "2048", "-np", "4", "-b", "512", "-ub", "512",
                                       "--no-webui"], stdout=open(out / "e5.log", "w"), stderr=subprocess.STDOUT))
        if use_cls:
            procs.append(subprocess.Popen([cpu, "-m", classifier_model, "--reranking", "--pooling", "rank", "--host",
                                           "127.0.0.1", "--port", str(CLS), "-c", "2048", "-np", "4", "-b", "512",
                                           "-ub", "512", "-t", "4", "--no-webui"],
                                          stdout=open(out / "classifier.log", "w"), stderr=subprocess.STDOUT))
        if llm != "none":
            args = ([cpu, "-m", llm_model, "-t", "8"] if cpu_llm else [vulkan, "-m", llm_model, "-ngl", "99"]) \
                + ["--host", "127.0.0.1", "--port", str(LLM), *PHONE_ARGS]
            info["llm_args"] = args
            procs.append(subprocess.Popen(args, stdout=open(out / "llm.log", "w"), stderr=subprocess.STDOUT))
            if wait(f"http://127.0.0.1:{LLM}/health") is None:
                raise SystemExit("LLM server did not start")
            os.environ.update({k: v for k, v in env.items() if k.startswith("TOWNPASS_")})
            sys.path.insert(0, str(backend_dir))
            from decision import POLICIES, system_prompt  # same warm-up as device_main.warm_up
            for task in POLICIES:
                get(f"http://127.0.0.1:{LLM}/v1/chat/completions",
                    {"messages": [{"role": "system", "content": system_prompt(task)},
                                  {"role": "user", "content": "{}"}], "temperature": 0, "max_tokens": 1})
        for url in [f"http://127.0.0.1:{E5_PORT}/health"] + ([f"http://127.0.0.1:{CLS}/health"] if use_cls else []):
            if wait(url) is None:
                raise SystemExit(f"{url} did not start")
        blog = open(out / "backend.log", "w", encoding="utf-8")
        procs.append(subprocess.Popen([sys.executable, "-X", "utf8", "server.py", "--port", str(BACKEND)],
                                      cwd=str(backend_dir), env=env, stdout=blog, stderr=subprocess.STDOUT))
        base = f"http://127.0.0.1:{BACKEND}"
        if wait(base + "/health", 300, lambda b: b.get("semantic_ready") and b.get("faq_entries")) is None:
            raise SystemExit("backend not ready")
        last = None
        for _ in range(60):
            count = get(base + "/health")["faq_entries"]
            if count == last:
                break
            last, _ = count, time.sleep(3)
        info["faq_entries"] = last
        jobs = [("dev", "evaluate.py", ["--base-url", base, "--set", "dev", "--output", str(out / "dev.json")]),
                ("holdout", "evaluate.py", ["--base-url", base, "--set", "holdout", "--output", str(out / "holdout.json")]),
                ("i18n", "eval_i18n.py", ["--base-url", base]),
                ("i18n_send", "eval_i18n.py", ["--base-url", base, "--send-language"]),
                ("colloquial", "eval_colloquial.py", ["--base-url", base, "--output", str(out / "colloquial.json")]),
                ("foreign", "eval_colloquial.py", ["--base-url", base, "--cases", "eval_foreign_holdout.json",
                                                   "--output", str(out / "foreign.json")]),
                ("cdev", "eval_colloquial.py", ["--base-url", base, "--cases", "eval_colloquial_dev.json",
                                                "--output", str(out / "cdev.json")]),
                ("creport", "eval_colloquial.py", ["--base-url", base, "--cases", "eval_colloquial_report_holdout.json",
                                                   "--output", str(out / "creport.json")]),
                ("guides", "eval_guides.py", ["--end-to-end", "--json", str(out / "guides.json")]),
                ("guides_holdout", "eval_guides.py", ["--end-to-end", "--cases", "data/guide_eval_holdout.json",
                                                      "--json", str(out / "guides_holdout.json")])]
        marks = {}
        for label, script, args in jobs:
            blog.flush()
            start = sum(1 for _ in open(out / "backend.log", encoding="utf-8", errors="replace"))
            started = time.monotonic()
            # eval_guides runs the assistant in-process: it gets the backend's environment
            with open(out / f"{label}.log", "w", encoding="utf-8") as handle:
                code = subprocess.call([sys.executable, "-X", "utf8", script, *args], cwd=str(backend_dir), env=env,
                                       stdout=handle, stderr=subprocess.STDOUT)
            time.sleep(1)
            blog.flush()
            end = sum(1 for _ in open(out / "backend.log", encoding="utf-8", errors="replace"))
            marks[label] = {"exit": code, "lines": [start, end], "wall_s": round(time.monotonic() - started)}
            print(name, label, marks[label], flush=True)
        info["marks"] = marks
    finally:
        for proc in reversed(procs):
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
        (out / "run.json").write_text(json.dumps(info, indent=1, ensure_ascii=False), encoding="utf-8")
        print("finished", name, flush=True)


if __name__ == "__main__":
    main()

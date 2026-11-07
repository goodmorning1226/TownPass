"""Build the FAQ index faq.py loads, with multilingual-e5-small on llama-server.

Usage (repo root):
  llama-server -m multilingual-e5-small-q8_0.gguf --embedding --pooling mean --port 8774 -c 2048 -np 4 -b 512 -ub 512
  python -X utf8 scripts/build_faq_index.py rag_handoff/reference/faq_rag.json <out dir> [--url http://127.0.0.1:8774] [--text dept_question]

Writes <out dir>/embeddings.bin (float32 LE [N, D], L2-normalised),
metadata.json ([{id, question, answer, department, category}] by row) and
model_info.json. Each FAQ is embedded as "passage: " + its text; --text picks
the text (docs/AI_FAQ_RAG.md section 6 compares them):
  question               the question only
  dept_question          "[department] question" (default)
  dept_question_answer   "[department] question\\nanswer", cut to the model's 512 tokens
"""
import argparse
import array
import json
import pathlib
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "assistant_backend"))
from faq import MODEL, PASSAGE_PREFIX, QUERY_PREFIX, embed_texts  # noqa: E402

TEXTS = {
    "question": lambda e: e["question"].strip(),
    "dept_question": lambda e: f"[{e['department']}] {e['question'].strip()}",
    "dept_question_answer": lambda e: f"[{e['department']}] {e['question'].strip()}\n{e['answer'].strip()}",
}
MAX_TOKENS = 500  # 512 positions minus <s>, </s> and a margin: re-tokenising cut text can add a token


def post(url, path, payload):
    request = urllib.request.Request(url + path, json.dumps(payload).encode("utf-8"),
                                     {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read())


def fit(url, text):
    """Cut text to the encoder's window, as sentence-transformers truncates."""
    tokens = post(url, "/tokenize", {"content": text, "add_special": False})["tokens"]
    if len(tokens) <= MAX_TOKENS:
        return text
    return post(url, "/detokenize", {"tokens": tokens[:MAX_TOKENS]})["content"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("out")
    parser.add_argument("--url", default="http://127.0.0.1:8774")
    parser.add_argument("--text", choices=sorted(TEXTS), default="dept_question")
    parser.add_argument("--gguf", default="multilingual-e5-small-q8_0.gguf", help="recorded in model_info.json")
    args = parser.parse_args()
    url = args.url.rstrip("/")
    data = json.loads(pathlib.Path(args.source).read_text(encoding="utf-8"))
    texts = [PASSAGE_PREFIX + TEXTS[args.text](entry) for entry in data]
    started = time.monotonic()
    with ThreadPoolExecutor(4) as pool:
        if args.text == "dept_question_answer":
            texts = list(pool.map(lambda text: fit(url, text), texts))
        batches = [texts[i:i + 8] for i in range(0, len(texts), 8)]
        vectors = [v for batch in pool.map(lambda b: embed_texts(url, b, timeout=900), batches) for v in batch]
    dim = len(vectors[0])
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    flat = array.array("f", (x for vector in vectors for x in vector))
    if sys.byteorder == "big":
        flat.byteswap()
    (out / "embeddings.bin").write_bytes(flat.tobytes())
    metadata = [{key: entry[key] for key in ("id", "question", "answer", "department", "category")} for entry in data]
    (out / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=1), encoding="utf-8")
    info = {"model": MODEL, "gguf": args.gguf, "runtime": "llama.cpp llama-server --embedding --pooling mean",
            "query_prefix": QUERY_PREFIX, "passage_prefix": PASSAGE_PREFIX, "text": args.text,
            "source": pathlib.Path(args.source).name, "dim": dim, "count": len(vectors), "normalized": True,
            "dtype": "float32", "layout": "row-major [N, D] little-endian"}
    (out / "model_info.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{len(vectors)} x {dim} in {time.monotonic() - started:.0f} s -> {out}")


if __name__ == "__main__":
    main()

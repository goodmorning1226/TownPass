"""Compute sentence embeddings for faq_rag.json.

Output layout (packaged for mobile):
    index/
        model_info.json     — model name, dim, count, normalization flag
        metadata.json       — [{id, question, answer, department, category}] aligned by row
        embeddings.bin      — float32 little-endian, shape [N, D], L2-normalised

The on-device app should:
  1. mmap embeddings.bin as float32 [N, D]
  2. embed the user query with the SAME model (shipped as ONNX)
  3. L2-normalise the query vector
  4. dot-product against the matrix (= cosine, because both sides are normalised)
  5. argpartition top-k, look up metadata.json[i] for each hit
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer

HERE = Path(__file__).parent
SRC = HERE / "faq_rag.json"
OUT_DIR = HERE / "index"

# Chinese-specialized, 512-dim, ~95 MB. Significantly better on zh-TW domain
# terms (考績乙等, 實價登錄, …) than multilingual MiniLM.
# Alternative for zh+en mix: sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
MODEL_NAME = "BAAI/bge-small-zh-v1.5"


def main() -> int:
    print(f"loading {SRC.name}…", file=sys.stderr)
    data = json.loads(SRC.read_text(encoding="utf-8"))
    print(f"  {len(data)} entries", file=sys.stderr)

    print(f"loading model {MODEL_NAME}…", file=sys.stderr)
    model = SentenceTransformer(MODEL_NAME)
    dim = model.get_sentence_embedding_dimension()
    print(f"  dim={dim}  max_seq={model.max_seq_length}", file=sys.stderr)

    # One chunk per FAQ: "[dept] Q\nA". Prepending department rescues short/
    # generic titles whose context lives only in the metadata — e.g. an entry
    # titled "外國籍有什麼優惠嗎?" from 動物園 never matches a query mentioning
    # "動物園" without this hint.
    # Long answers (p90=452 chars, max ~8000) are token-truncated to 128 by
    # the model — fine for FAQ-granularity retrieval; the Q+opening of A
    # carries the signal.
    chunks = [
        f"[{e['department']}] {e['question']}\n{e['answer']}"
        for e in data
    ]

    print("encoding…", file=sys.stderr)
    t0 = time.time()
    embeddings = model.encode(
        chunks,
        batch_size=32,
        show_progress_bar=True,
        convert_to_numpy=True,
        normalize_embeddings=True,
    ).astype(np.float32)
    dt = time.time() - t0
    print(f"  encoded {len(chunks)} in {dt:.1f}s ({len(chunks)/dt:.1f}/s)", file=sys.stderr)

    assert embeddings.shape == (len(data), dim), embeddings.shape

    OUT_DIR.mkdir(exist_ok=True)

    # embeddings.bin — raw float32 little-endian, row-major [N, D].
    emb_path = OUT_DIR / "embeddings.bin"
    embeddings.tofile(emb_path)

    # metadata.json — same order as embedding rows.
    metadata = [
        {
            "id": e["id"],
            "question": e["question"],
            "answer": e["answer"],
            "department": e["department"],
            "category": e["category"],
        }
        for e in data
    ]
    (OUT_DIR / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    (OUT_DIR / "model_info.json").write_text(
        json.dumps(
            {
                "model": MODEL_NAME,
                "dim": dim,
                "count": len(data),
                "normalized": True,
                "dtype": "float32",
                "layout": "row-major [N, D] little-endian",
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    size_mb = emb_path.stat().st_size / 1024 / 1024
    print(f"wrote {OUT_DIR}/", file=sys.stderr)
    print(f"  embeddings.bin  {size_mb:.2f} MB", file=sys.stderr)
    print(f"  metadata.json", file=sys.stderr)
    print(f"  model_info.json", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

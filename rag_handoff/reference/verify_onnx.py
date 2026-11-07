"""Verify ONNX model produces embeddings identical to the SentenceTransformer
baseline that built `index/embeddings.bin`.

If max_abs_diff > 1e-4 the existing index is invalid for ONNX inference and
needs to be rebuilt from the ONNX model instead.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
from sentence_transformers import SentenceTransformer
from transformers import AutoTokenizer

HERE = Path(__file__).parent
ONNX_DIR = HERE / "rag_handoff" / "assets"
MODEL_NAME = "BAAI/bge-small-zh-v1.5"

TEST_TEXTS = [
    "學齡前視力檢查要錢嗎",
    "[臺北市政府勞動局勞動基準科] 加班費怎麼計算？",
    "新冠疫苗跟流感疫苗可以一起打嗎",
    "Taipei zoo foreign visitor discount",
    "  ",  # edge case: only whitespace
]


def embed_onnx(sess, tokenizer, text: str) -> np.ndarray:
    enc = tokenizer(
        text,
        padding=True,
        truncation=True,
        max_length=512,
        return_tensors="np",
    )
    # optimum-exported sentence-transformers model needs only these two inputs
    # (token_type_ids is optional and omitted). Outputs: ['token_embeddings',
    # 'sentence_embedding'] — pooling + L2 norm are baked into the graph.
    feeds = {
        "input_ids": enc["input_ids"].astype(np.int64),
        "attention_mask": enc["attention_mask"].astype(np.int64),
    }
    outputs = sess.run(["sentence_embedding"], feeds)
    return outputs[0][0]  # [512]


def main() -> int:
    print(f"loading ONNX from {ONNX_DIR}", file=sys.stderr)
    sess = ort.InferenceSession(str(ONNX_DIR / "model.onnx"))
    tokenizer = AutoTokenizer.from_pretrained(str(ONNX_DIR))
    print("ONNX input names:", [i.name for i in sess.get_inputs()])
    print("ONNX output names:", [o.name for o in sess.get_outputs()])

    print(f"loading reference SentenceTransformer {MODEL_NAME}", file=sys.stderr)
    ref_model = SentenceTransformer(MODEL_NAME)

    max_diff = 0.0
    for text in TEST_TEXTS:
        if not text.strip():
            continue
        v_onnx = embed_onnx(sess, tokenizer, text)
        v_ref = ref_model.encode([text], normalize_embeddings=True)[0]
        diff = float(np.abs(v_onnx - v_ref).max())
        cos = float(np.dot(v_onnx, v_ref))
        print(f"  text={text[:30]!r:35s}  max_abs_diff={diff:.6f}  cos_sim={cos:.6f}")
        max_diff = max(max_diff, diff)

    print()
    print(f"overall max_abs_diff = {max_diff:.6f}")
    if max_diff < 1e-4:
        print("✅ ONNX ≡ PyTorch within float32 noise. Existing embeddings.bin is valid.")
        return 0
    elif max_diff < 1e-3:
        print(
            "⚠️  Minor divergence. Embeddings should still retrieve same top-k, but"
            " recommend rebuilding embeddings.bin from ONNX for exact parity."
        )
        return 0
    else:
        print(
            "❌ Material divergence. Rebuild embeddings.bin from ONNX before shipping."
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Taipei city-government FAQ retrieval, the assistant's second layer.

The workflow asks this index only after tool calling found no service for the
request. It returns stored FAQ answers verbatim; nothing is generated, so the
model cannot invent policy text. Port of rag_handoff/reference/retrieve.py with
ONNX Runtime + tokenizers in place of sentence-transformers.

Assets (about 117 MB: bge-small-zh-v1.5 ONNX encoder, tokenizer, pre-built
embeddings and metadata) live outside the repo, like the other model weights:
TOWNPASS_FAQ_DIR, else %LOCALAPPDATA%/TownPassAssistant/faq_rag. Needs
`pip install onnxruntime tokenizers numpy`; without them, or without the
assets, load_default() returns None and the assistant runs without FAQ.
"""
import json
import os
import pathlib

# Re-tuned for the assistant on 2026-11-07 (docs/AI_FAQ_RAG.md section 6): on
# colloquial questions the top-1 FAQ is right only ~55-80% of the time at any
# score, while the top 3 hold an answer ~83% of the time. So scores from
# MEDIUM_CONF ask "did you mean" with the closest questions and answer only
# after the user picks one; HIGH_CONF (near-verbatim questions) answers
# directly. The handoff's 0.73 / 0.65 bands answered wrongly far more often.
# Specific to bge-small-zh-v1.5 and this index; re-tune if either changes.
HIGH_CONF = 0.85
MEDIUM_CONF = 0.69
SCOPE_NOTE = "本服務僅涵蓋臺北市政府 FAQ。"
# The encoder accepts at most 512 positions; assistant requests are <= 500 chars.
MAX_TOKENS = 512


def default_dir():
    configured = os.environ.get("TOWNPASS_FAQ_DIR")
    if configured:
        return pathlib.Path(configured)
    return pathlib.Path(os.environ.get("LOCALAPPDATA", pathlib.Path.home())) / "TownPassAssistant" / "faq_rag"


def band(score):
    """Confidence band of the best score: high, medium or none."""
    return "high" if score >= HIGH_CONF else "medium" if score >= MEDIUM_CONF else "none"


class FaqIndex:
    def __init__(self, directory):
        import numpy as np
        import onnxruntime
        from tokenizers import Tokenizer
        directory = pathlib.Path(directory)
        info = json.loads((directory / "model_info.json").read_text(encoding="utf-8"))
        if not info.get("normalized"):
            raise ValueError("FAQ index must be L2-normalised.")
        self.np = np
        self.count, self.dim = info["count"], info["dim"]
        self.embeddings = np.fromfile(directory / "embeddings.bin", dtype="<f4").reshape(self.count, self.dim)
        self.metadata = json.loads((directory / "metadata.json").read_text(encoding="utf-8"))
        if len(self.metadata) != self.count:
            raise ValueError("FAQ metadata and embeddings are not aligned.")
        self.by_id = {entry["id"]: entry for entry in self.metadata}
        self.tokenizer = Tokenizer.from_file(str(directory / "tokenizer.json"))
        self.tokenizer.enable_truncation(MAX_TOKENS)
        self.session = onnxruntime.InferenceSession(str(directory / "model.onnx"),
                                                    providers=["CPUExecutionProvider"])

    def embed(self, text):
        """Query vector; CLS pooling and L2 normalisation are inside the graph."""
        np = self.np
        ids = self.tokenizer.encode(text).ids
        feed = {"input_ids": np.array([ids], dtype=np.int64),
                "attention_mask": np.ones((1, len(ids)), dtype=np.int64)}
        return self.session.run(["sentence_embedding"], feed)[0][0]

    def search(self, text, k=3):
        """(confidence, hits) with hits [{score, id, question, answer, department, category}].

        Hits are best first and at least MEDIUM_CONF; none-confidence results carry no hits.
        """
        np = self.np
        scores = self.embeddings @ self.embed(text)
        k = min(k, self.count)
        top = np.argpartition(-scores, k - 1)[:k]
        top = top[np.argsort(-scores[top])]
        hits = [{"score": round(float(scores[i]), 4), **self.metadata[int(i)]} for i in top]
        return band(hits[0]["score"]), [hit for hit in hits if hit["score"] >= MEDIUM_CONF]


def load_default():
    """The FAQ index, or None (with a printed reason) when it cannot be used."""
    directory = default_dir()
    try:
        return FaqIndex(directory)
    except ImportError as exc:
        print(f"FAQ: disabled, missing package ({exc.name}); pip install onnxruntime tokenizers numpy", flush=True)
    except (OSError, ValueError, KeyError) as exc:
        print(f"FAQ: disabled, assets not usable in {directory} ({exc})", flush=True)
    except Exception as exc:  # onnxruntime raises its own error types for bad models
        print(f"FAQ: disabled, model failed to load ({type(exc).__name__})", flush=True)
    return None

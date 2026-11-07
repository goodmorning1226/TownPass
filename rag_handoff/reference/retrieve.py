"""Reference retrieval implementation — pure numpy cosine top-k.

This is the exact algorithm the on-device Flutter app will reimplement:
  1. mmap `embeddings.bin` as float32 [N, D]
  2. embed the query with the SAME model (shipped as ONNX in mobile)
  3. L2-normalise query
  4. dot-product against the matrix (= cosine, both sides normalised)
  5. argpartition top-k
  6. apply confidence thresholds — see HIGH_CONF / LOW_CONF

Confidence bands (empirically tuned against bge-small-zh-v1.5 on this corpus):
    top1 score ≥ 0.73  → "high"    — show normally
    top1 score ≥ 0.65  → "low"     — show with "參考答案" caveat
    top1 score <  0.65 → "none"    — tell the user "找不到，撥 1999"

Usage as library:
    from retrieve import Retriever
    r = Retriever()
    result = r.search("學齡前視力檢查要錢嗎", k=5)
    if result.confidence == "none":
        print(result.message)
    else:
        for h in result.hits: ...
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

import numpy as np
from sentence_transformers import SentenceTransformer

HERE = Path(__file__).parent
INDEX_DIR = HERE / "index"

HIGH_CONF = 0.73
LOW_CONF = 0.65

NO_MATCH_MESSAGE = (
    "抱歉，目前沒有找到相關的台北市府 FAQ。"
    "如需進一步協助，請撥打市民熱線 1999（外縣市 02-27208889）。"
)
LOW_CONF_CAVEAT = (
    "以下是最接近的參考答案，但信心較低，建議撥打 1999 再次確認。"
)

Confidence = Literal["high", "low", "none"]


@dataclass(slots=True)
class Hit:
    score: float
    id: str
    question: str
    answer: str
    department: str
    category: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "score": round(float(self.score), 4),
            "id": self.id,
            "question": self.question,
            "answer": self.answer,
            "department": self.department,
            "category": self.category,
        }


@dataclass(slots=True)
class SearchResult:
    hits: list[Hit]
    confidence: Confidence
    message: str | None = None

    @property
    def top_score(self) -> float:
        return self.hits[0].score if self.hits else 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "confidence": self.confidence,
            "message": self.message,
            "top_score": round(self.top_score, 4),
            "hits": [h.to_dict() for h in self.hits],
        }


class Retriever:
    def __init__(self, index_dir: Path = INDEX_DIR) -> None:
        info = json.loads((index_dir / "model_info.json").read_text(encoding="utf-8"))
        self.model_name: str = info["model"]
        self.dim: int = info["dim"]
        self.count: int = info["count"]
        assert info["normalized"], "index must be L2-normalised"

        raw = np.fromfile(index_dir / "embeddings.bin", dtype=np.float32)
        self.embeddings = raw.reshape(self.count, self.dim)

        self.metadata: list[dict[str, Any]] = json.loads(
            (index_dir / "metadata.json").read_text(encoding="utf-8")
        )
        assert len(self.metadata) == self.count

        self.model = SentenceTransformer(self.model_name)

    def _embed_query(self, query: str) -> np.ndarray:
        vec = self.model.encode(
            [query],
            convert_to_numpy=True,
            normalize_embeddings=True,
        )[0]
        return vec.astype(np.float32)

    def search(
        self,
        query: str,
        k: int = 5,
        category: str | None = None,
    ) -> SearchResult:
        q = self._embed_query(query)
        scores = self.embeddings @ q  # cosine, both sides normalised

        if category is not None:
            mask = np.array(
                [m["category"] == category for m in self.metadata], dtype=bool
            )
            scores = np.where(mask, scores, -np.inf)

        # argpartition is O(N) vs full sort O(N log N) — matters less at N=8k
        # but it's the pattern mobile will copy.
        k = min(k, self.count)
        top_idx = np.argpartition(-scores, k - 1)[:k]
        top_idx = top_idx[np.argsort(-scores[top_idx])]

        hits = []
        for i in top_idx:
            m = self.metadata[int(i)]
            hits.append(
                Hit(
                    score=float(scores[int(i)]),
                    id=m["id"],
                    question=m["question"],
                    answer=m["answer"],
                    department=m["department"],
                    category=m["category"],
                )
            )

        top = hits[0].score if hits else 0.0
        if top >= HIGH_CONF:
            return SearchResult(hits=hits, confidence="high")
        if top >= LOW_CONF:
            return SearchResult(hits=hits, confidence="low", message=LOW_CONF_CAVEAT)
        return SearchResult(hits=[], confidence="none", message=NO_MATCH_MESSAGE)


if __name__ == "__main__":
    import sys

    r = Retriever()
    query = " ".join(sys.argv[1:]) or "學齡前視力檢查要錢嗎"
    print(f"query: {query}\n")
    result = r.search(query, k=5)
    print(f"confidence: {result.confidence}  (top_score={result.top_score:.3f})")
    if result.message:
        print(f"message: {result.message}")
    print()
    for i, h in enumerate(result.hits, 1):
        print(f"[{i}] score={h.score:.3f}  {h.category} / {h.department}")
        print(f"    Q: {h.question}")
        preview = h.answer.replace("\n", " ")[:200]
        print(f"    A: {preview}{'…' if len(h.answer) > 200 else ''}")
        print()

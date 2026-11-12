"""Writes assets/assistant/models.json, the model download manifest (docs/AI_MODEL_DOWNLOAD.md).

Run on the computer after a model or the FAQ index changes; it reads each file
once for its size and SHA-256. The default paths are the ones
scripts/push_assistant_models.ps1 pushes. Files from the original authors keep
their Hugging Face URL (their size and SHA-256 matched those listings on
2026-11-10); our own conversions and the FAQ index have only a path, served
from the manifest's team_url (or TOWNPASS_MODEL_BASE_URL on the phone).
The decision classifier (id "classifier", ASSISTANT_DECISION_MODEL=classifier,
docs/AI_DECISION_CLASSIFIER.md) is one of ours too: it is offered from team_url only
once the owner has uploaded it there; until then test it with a local mirror
(scripts/serve_assistant_models.py) or push it with push_assistant_models.ps1
-DecisionModel classifier.

  python -X utf8 scripts/build_model_manifest.py [--team-url https://huggingface.co/<team>/<repo>/resolve/main]
"""
import argparse
import hashlib
import json
import os
import pathlib

MODELS = r"D:\TownPassAssistant\models"
FAQ = os.path.join(os.environ.get("LOCALAPPDATA", ""), "TownPassAssistant", "faq_rag")
HF = "https://huggingface.co"

# id, name on the phone, part, local file, mirror path, upstream URL, extra fields
FILES = [
    ("langid", "ggml-whisper-langid.bin", "core", rf"{MODELS}\asr-ablation\ggml-tiny-q8_0.bin",
     "whisper/ggml-tiny-q8_0.bin", f"{HF}/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q8_0.bin",
     {"server": "gate", "license": "MIT (OpenAI Whisper tiny, whisper.cpp ggml)"}),
    ("speech", "ggml-whisper-multilingual.bin", "core", rf"{MODELS}\asr-ablation\ggml-small-q8_0.bin",
     "whisper/ggml-small-q8_0.bin", f"{HF}/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin",
     {"server": "multilingual", "license": "MIT (OpenAI Whisper small, whisper.cpp ggml)"}),
    ("embedding", "multilingual-e5-small-q8_0.gguf", "core", rf"{MODELS}\device\multilingual-e5-small-q8_0.gguf",
     "e5/multilingual-e5-small-q8_0.gguf", None,
     {"server": "embedding", "license": "MIT (Microsoft multilingual-e5-small; GGUF q8_0 by this project)"}),
    ("faq-embeddings", "faq_rag/embeddings.bin", "core", os.path.join(FAQ, "embeddings.bin"),
     "faq_rag/embeddings.bin", None,
     {"server": "embedding", "license": "Taipei City FAQ, Open Government Data License v1.0 (data.taipei)"}),
    ("faq-metadata", "faq_rag/metadata.json", "core", os.path.join(FAQ, "metadata.json"),
     "faq_rag/metadata.json", None,
     {"server": "embedding", "license": "Taipei City FAQ, Open Government Data License v1.0 (data.taipei)"}),
    ("faq-model-info", "faq_rag/model_info.json", "core", os.path.join(FAQ, "model_info.json"),
     "faq_rag/model_info.json", None, {"server": "embedding"}),
    ("vietnamese", "ggml-whisper-vietnamese.bin", "core", rf"{MODELS}\vietnamese\ggml-phowhisper-base-q8_0.bin",
     "vietnamese/ggml-phowhisper-base-q8_0.bin", None,
     {"platforms": ["android"], "license": "BSD-3-Clause (VinAI PhoWhisper-base; ggml q8_0 by this project)"}),
    ("ministral", "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", "decision",
     rf"{MODELS}\device\Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", "decision/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
     f"{HF}/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
     {"server": "decision", "decision_model": "ministral", "license": "Apache-2.0 (Mistral AI)"}),
    ("gemma", "gemma-4-E2B-it-Q4_0.gguf", "decision",
     r"D:\TownPassAssistant\model-study\dl-gemma4-e2b-q4_0\gemma-4-E2B-it-Q4_0.gguf", "decision/gemma-4-E2B-it-Q4_0.gguf",
     f"{HF}/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf",
     {"server": "decision", "decision_model": "gemma", "platforms": ["android"], "license": "Gemma Terms of Use (Google)"}),
    # Option B' (docs/AI_DECISION_CLASSIFIER.md sections 10-12): the decision classifier
    # replaces the decision model (ASSISTANT_DECISION_MODEL=classifier); 132 MB, so
    # every tier gets it (models.Downloads.parts_for_phone).
    ("classifier", "townpass-decision-e5-ce-v1-q8_0.gguf", "decision",
     r"D:\TownPassAssistant\decision-classifier\models\townpass-decision-e5-ce-v1-q8_0.gguf",
     "decision/townpass-decision-e5-ce-v1-q8_0.gguf", None,
     {"server": "classifier", "decision_model": "classifier", "platforms": ["android", "ios"],
      "license": "MIT (cross-encoder fine-tuned by this project from Microsoft multilingual-e5-small; GGUF q8_0)"}),
    ("taiwanese", "ggml-whisper-taiwanese.bin", "taiwanese", rf"{MODELS}\taiwanese\ggml-breeze-asr-26-q8_0.bin",
     "taiwanese/ggml-breeze-asr-26-q8_0.bin", None,
     {"tiers": ["full"], "platforms": ["android"],
      "license": "Apache-2.0 (MediaTek Research Breeze-ASR-26; ggml q8_0 by this project)"}),
    ("taiwanese-q4", "ggml-whisper-taiwanese.bin", "taiwanese", rf"{MODELS}\taiwanese\ggml-breeze-asr-26-q4_k.bin",
     "taiwanese/ggml-breeze-asr-26-q4_k.bin", None,
     {"tiers": ["standard"], "platforms": ["android"],
      "license": "Apache-2.0 (MediaTek Research Breeze-ASR-26; ggml q4_K by this project)"}),
    # iPhone: q4_K on every tier (2026-11-13). The limit there is the App's own memory
    # budget, not the phone's RAM: q8_0 (~2.5 GB with its buffers) ran out of it on a
    # 12 GB iPhone 17 Pro Max and whisper.cpp aborted the App. Swap the file here (and
    # in OnDeviceAssistant.swift's taiwaneseOverhead if it is not a Whisper large model).
    ("taiwanese-q4-ios", "ggml-whisper-taiwanese.bin", "taiwanese", rf"{MODELS}\taiwanese\ggml-breeze-asr-26-q4_k.bin",
     "taiwanese/ggml-breeze-asr-26-q4_k.bin", None,
     {"tiers": ["full", "standard"], "platforms": ["ios"],
      "license": "Apache-2.0 (MediaTek Research Breeze-ASR-26; ggml q4_K by this project)"}),
]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--team-url", default="", help="where path is served from (the team's Hugging Face repo)")
    parser.add_argument("--output", default=str(pathlib.Path(__file__).resolve().parent.parent
                                                / "assets" / "assistant" / "models.json"))
    args = parser.parse_args()
    files = []
    for file_id, name, part, local, path, url, extra in FILES:
        entry = {"id": file_id, "name": name, "part": part, "size": os.path.getsize(local),
                 "sha256": sha256(local), "path": path}
        if url:
            entry["url"] = url
        entry.update(extra)
        files.append(entry)
        print(f"{file_id}: {entry['size'] >> 20} MB {entry['sha256'][:12]}", flush=True)
    manifest = {"version": 1, "team_url": args.team_url, "files": files}
    pathlib.Path(args.output).write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()

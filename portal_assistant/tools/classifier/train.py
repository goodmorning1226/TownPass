"""Fine-tune a multilingual encoder as a (request, candidate) cross-encoder.

The head matches llama.cpp's BERT rank pooling (llama-graph.cpp, POOLING_TYPE_RANK):
hidden state of the first token -> one linear layer -> one logit; token type ids
are all 0 (llama.cpp always uses token-type row 0); the pair is encoded as
<s> query </s></s> document </s> (XLM-R pair format = llama-server's rerank prompt).
No BERT pooler is used, so the exported BertForSequenceClassification's pooler
weights are unused (the GGUF converter drops them).

Usage: train.py <base dir> <out dir> [--epochs 4] [--lr 4e-5] [--batch 32] [--cpu]
--train / --dev default to <work>/data/pairs_train.jsonl / pairs_dev.jsonl (v1); classifier v2 was
trained with --train <work>/data/v2/pairs_train.jsonl --dev <work>/data/v2/pairs_dev.jsonl --max-len 160.
"""
import argparse
import json
import math
import pathlib
import random
import shutil
import sys
import time

import numpy as np
import torch
from torch import nn
from transformers import AutoTokenizer, BertForSequenceClassification, BertModel, get_linear_schedule_with_warmup

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cls_paths  # noqa: E402


class CrossEncoder(nn.Module):
    def __init__(self, base):
        super().__init__()
        self.bert = BertModel.from_pretrained(base, add_pooling_layer=False)
        self.classifier = nn.Linear(self.bert.config.hidden_size, 1)
        nn.init.normal_(self.classifier.weight, std=0.02)
        nn.init.zeros_(self.classifier.bias)

    def forward(self, input_ids, attention_mask):
        hidden = self.bert(input_ids=input_ids, attention_mask=attention_mask,
                           token_type_ids=torch.zeros_like(input_ids)).last_hidden_state[:, 0]
        return self.classifier(hidden).squeeze(-1)


def load(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def batches(rows, tok, size, max_len, shuffle, rng):
    order = list(range(len(rows)))
    if shuffle:
        rng.shuffle(order)
    for start in range(0, len(order), size):
        chunk = [rows[i] for i in order[start:start + size]]
        enc = tok([r["query"] for r in chunk], [r["doc"] for r in chunk], truncation="only_second",
                  max_length=max_len, padding=True, return_tensors="pt")
        yield enc["input_ids"], enc["attention_mask"], torch.tensor([float(r["label"]) for r in chunk]), chunk


def auc(labels, scores):
    labels, scores = np.asarray(labels), np.asarray(scores)
    order = scores.argsort()
    ranks = np.empty(len(scores))
    ranks[order] = np.arange(1, len(scores) + 1)
    pos = labels == 1
    n_pos, n_neg = pos.sum(), (~pos).sum()
    return float((ranks[pos].sum() - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)) if n_pos and n_neg else float("nan")


@torch.no_grad()
def predict(model, rows, tok, device, max_len, size=128):
    model.eval()
    out = []
    for ids, mask, _, _ in batches(rows, tok, size, max_len, False, None):
        with torch.autocast(device_type=device.type, dtype=torch.float16, enabled=device.type == "cuda"):
            out += model(ids.to(device), mask.to(device)).float().cpu().tolist()
    model.train()
    return out


def export(model, base, out):
    """HF BertForSequenceClassification (num_labels=1) with the trained encoder and head."""
    hf = BertForSequenceClassification.from_pretrained(base, num_labels=1)
    hf.bert.load_state_dict(model.bert.state_dict(), strict=False)
    hf.classifier.load_state_dict(model.classifier.state_dict())
    hf.config.id2label, hf.config.label2id = {0: "score"}, {"score": 0}
    hf.config.architectures = ["BertForSequenceClassification"]
    hf.save_pretrained(out, safe_serialization=True)
    for name in ("sentencepiece.bpe.model", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        if (pathlib.Path(base) / name).exists():
            shutil.copy(pathlib.Path(base) / name, pathlib.Path(out) / name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("base")
    parser.add_argument("out")
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--lr", type=float, default=4e-5)
    parser.add_argument("--head-lr", type=float, default=1e-3)
    parser.add_argument("--batch", type=int, default=32)
    parser.add_argument("--max-len", type=int, default=96)
    parser.add_argument("--pos-weight", type=float, default=2.0)
    parser.add_argument("--train", help="training pairs (default <work>/data/pairs_train.jsonl)")
    parser.add_argument("--dev", help="dev pairs, epoch choice only (default <work>/data/pairs_dev.jsonl)")
    parser.add_argument("--cpu", action="store_true")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--train-embeddings", action="store_true",
                        help="also train the 96M-parameter word embeddings (frozen by default: keeps the "
                             "multilingual vocabulary aligned and needs ~1 GB of GPU memory instead of ~2.5 GB)")
    cls_paths.work_argument(parser)
    args = parser.parse_args()
    cls_paths.set_work(args.work)
    if not args.train:
        args.train = str(cls_paths.work_dir() / "data" / "pairs_train.jsonl")
    if not args.dev:
        args.dev = str(cls_paths.work_dir() / "data" / "pairs_dev.jsonl")
    torch.manual_seed(args.seed)
    rng = random.Random(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() and not args.cpu else "cpu")
    tok = AutoTokenizer.from_pretrained(args.base)
    train, dev = load(pathlib.Path(args.train)), load(pathlib.Path(args.dev))
    model = CrossEncoder(args.base).to(device)
    if not args.train_embeddings:
        model.bert.embeddings.word_embeddings.weight.requires_grad_(False)
    head = [p for n, p in model.named_parameters() if n.startswith("classifier")]
    body = [p for n, p in model.named_parameters() if not n.startswith("classifier") and p.requires_grad]
    optim = torch.optim.AdamW([{"params": body, "lr": args.lr}, {"params": head, "lr": args.head_lr}],
                              weight_decay=0.01)
    steps = args.epochs * math.ceil(len(train) / args.batch)
    sched = get_linear_schedule_with_warmup(optim, int(0.1 * steps), steps)
    scaler = torch.amp.GradScaler("cuda", enabled=device.type == "cuda")
    loss_fn = nn.BCEWithLogitsLoss(pos_weight=torch.tensor(args.pos_weight, device=device))
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    log = {"args": vars(args), "device": str(device), "train_pairs": len(train), "dev_pairs": len(dev), "epochs": []}
    print(f"device={device} train={len(train)} dev={len(dev)} steps={steps}", flush=True)
    started = time.time()
    for epoch in range(1, args.epochs + 1):
        total, n = 0.0, 0
        for ids, mask, labels, _ in batches(train, tok, args.batch, args.max_len, True, rng):
            with torch.autocast(device_type=device.type, dtype=torch.float16, enabled=device.type == "cuda"):
                logits = model(ids.to(device), mask.to(device))
            loss = loss_fn(logits.float(), labels.to(device))
            optim.zero_grad()
            scaler.scale(loss).backward()
            scaler.unscale_(optim)
            torch.nn.utils.clip_grad_norm_([p for p in model.parameters() if p.requires_grad], 1.0)
            scaler.step(optim)
            scaler.update()
            sched.step()
            total += loss.item() * len(labels)
            n += len(labels)
        scores = predict(model, dev, tok, device, args.max_len)
        labels = [r["label"] for r in dev]
        services = [i for i, r in enumerate(dev) if not r["candidate"].startswith("__")]
        row = {"epoch": epoch, "train_loss": round(total / n, 4), "dev_auc": round(auc(labels, scores), 4),
               "dev_auc_services": round(auc([labels[i] for i in services], [scores[i] for i in services]), 4),
               "minutes": round((time.time() - started) / 60, 1)}
        log["epochs"].append(row)
        print(json.dumps(row), flush=True)
        epoch_dir = out / f"epoch{epoch}"
        export(model, args.base, epoch_dir)
        (epoch_dir / "dev_scores.json").write_text(json.dumps(scores), encoding="utf-8")
    (out / "train_log.json").write_text(json.dumps(log, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()

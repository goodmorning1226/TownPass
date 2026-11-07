"""Check llama-server's multilingual-e5-small embeddings against PyTorch.

Usage: python -I rag_handoff/reference/verify_e5_gguf.py <HF model dir> <server URL> [<server URL> ...]
Needs torch + transformers (e.g. D:/TownPassAssistant/convert-venv). The server
runs `llama-server --embedding --pooling mean -m multilingual-e5-small-*.gguf`.
Reference: the model card's recipe, mean pooling over the attention mask + L2.
Prints the cosine between the two vectors per sentence; the index is valid
for the GGUF model when every cosine is > 0.99.
"""
import json
import sys
import urllib.request

import torch
import torch.nn.functional as F
from transformers import AutoModel, AutoTokenizer

TEXTS = [
    "query: 學齡前視力檢查要錢嗎",
    "query: 水費逾期未繳怎麼辦",
    "query: 新冠疫苗跟流感疫苗可以一起打嗎",
    "query: 考績乙等要怎麼申訴",
    "query: 台北市長是誰",
    "query: 今天天氣怎麼樣",
    "query: 鳳梨披薩好吃嗎",
    "query: 外國人可以免費看動物園嗎",
    "query: How do I apply for a low-income household subsidy in Taipei?",
    "query: 台北の動物園は外国人も無料ですか",
    "query: Làm thế nào để đăng ký kết hôn ở Đài Bắc?",
    "query: Bagaimana cara membayar tagihan air yang terlambat?",
    "query: ฉันจะขอรับเงินช่วยเหลือผู้สูงอายุได้อย่างไร",
    "query: 嗯",
    "passage: [臺北自來水事業處] 水費逾期未繳怎麼辦？",
    "passage: 外國籍有什麼優惠嗎?",
    "passage: [臺北市政府勞動局勞動基準科] 加班費怎麼計算？",
    "passage: 申請低收入戶需要準備哪些文件？請攜帶身分證、戶口名簿及相關所得證明至戶籍所在地區公所社會課辦理。",
    "passage: 臺北市立動物園的開放時間為每日上午9時至下午5時，除夕休園一天。",
    "passage: " + "臺北市政府" * 150,  # longer than 512 tokens: both sides truncate
]


def server_vectors(url, texts):
    request = urllib.request.Request(url.rstrip("/") + "/v1/embeddings", json.dumps({"input": texts}).encode("utf-8"),
                                     {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = json.loads(response.read())["data"]
    return torch.tensor([item["embedding"] for item in sorted(data, key=lambda d: d["index"])])


def main():
    model_dir, urls = sys.argv[1], sys.argv[2:]
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModel.from_pretrained(model_dir).eval()
    batch = tokenizer(TEXTS, max_length=512, padding=True, truncation=True, return_tensors="pt")
    with torch.no_grad():
        hidden = model(**batch).last_hidden_state
    mask = batch["attention_mask"].unsqueeze(-1).float()
    reference = F.normalize((hidden * mask).sum(1) / mask.sum(1), dim=1)
    worst = 1.0
    for url in urls:
        got = F.normalize(server_vectors(url, TEXTS), dim=1)
        cosines = (got * reference).sum(1)
        print(url)
        for text, cosine in zip(TEXTS, cosines.tolist()):
            print(f"  {cosine:.5f}  {text[:40]}")
        print(f"  min {cosines.min():.5f}  mean {cosines.mean():.5f}")
        worst = min(worst, float(cosines.min()))
    return 0 if worst > 0.99 else 1


if __name__ == "__main__":
    sys.exit(main())

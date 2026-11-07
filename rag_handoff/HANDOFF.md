# TownPass FAQ-RAG Integration Handoff

> **Purpose** — give the TownPass Flutter agent everything needed to wire an
> on-device, Chinese-FAQ semantic search into the app, without needing to
> reason about the index / model pipeline.
>
> **Source workspace** — `C:\Users\reg94\Desktop\Taipeicodefest2026`
> (Python dev scratchpad; stays separate from the Flutter repo).
> **This handoff** — `C:\Users\reg94\Desktop\Taipeicodefest2026\rag_handoff\`

---

## TL;DR

- 8 121 Taipei-gov FAQ entries, pre-embedded with **BAAI/bge-small-zh-v1.5**
  (512-dim, CLS pooling, L2-normalised). Index is 15.86 MB.
- Ship `assets/` (117 MB) inside the app bundle; everything runs on-device.
- Flutter integration: tokenise query → run ONNX model → cosine against
  pre-built matrix → top-k with a two-tier confidence guard.
- Recommended Flutter package: **`flutter_edge_ai`** (bundles ONNX Runtime +
  BERT WordPiece tokenizer for iOS & Android). Alternative: raw
  `onnxruntime` package + custom tokenizer via `flutter_rust_bridge`.

---

## 1. Artifact manifest

```
rag_handoff/
├── HANDOFF.md                     ← this doc
├── smoke_tests.json               ← 19 fixtures the Flutter side can replay
├── reference/                     ← Python reference implementations
│   ├── retrieve.py                  the authoritative search algorithm
│   ├── build_index.py               how embeddings.bin was produced
│   ├── build_rag_dataset.py         how metadata.json was produced
│   └── verify_onnx.py               ONNX ≡ PyTorch parity check
└── assets/                        ← ship ALL of these inside the app
    ├── model.onnx                   94.85 MB — the encoder
    ├── tokenizer.json              439 KB — HF fast-tokenizer (preferred)
    ├── vocab.txt                   109 KB — WordPiece fallback
    ├── tokenizer_config.json       1 KB
    ├── special_tokens_map.json     1 KB
    ├── config.json                 1 KB — BERT config (for sanity)
    ├── embeddings.bin              15.86 MB — float32 [8121, 512], L2-norm
    ├── metadata.json               6.67 MB — aligned with embeddings rows
    └── model_info.json             167 B — dim/count/layout summary
```

**Bundle size estimate**: ~**117 MB** of assets. The APK/IPA will also
include ONNX Runtime native libs (~15–25 MB extra).

### Where to put these in TownPass

Copy the whole `assets/` directory into:

```
TownPass/assets/faq_rag/
```

Then register in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/faq_rag/
```

Per AGENTS.md §4, `assets/` is the correct location for shipped resources.
Keep everything under a `faq_rag/` sub-folder so future RAG variants don't
collide. **Do not** drop these in `lib/` — they're binary assets, not code.

---

## 2. Data pipeline (reference only — don't re-run on Flutter side)

```
常見問答.json (Taipei gov FAQ dump, 10 MB, HTML-laden)
        │
        │ build_rag_dataset.py (NFKC-normalise, HTML strip,
        │                       drop one-off events / too-short)
        ▼
faq_rag.json (8121 clean entries, 6.6 MB)
        │
        │ build_index.py  (sentence-transformers encode with
        │                  chunk = "[dept] Q\nA", L2 norm)
        ▼
index/
├── embeddings.bin   float32 [8121, 512]
├── metadata.json    [{id, question, answer, department, category}]
└── model_info.json
        │
        │ optimum.exporters.onnx (sentence-transformers → ONNX)
        ▼
assets/model.onnx + tokenizer.*
```

Rebuilding only matters if the FAQ corpus changes. For now treat the shipped
artifacts as the ground truth.

**Important chunking detail**: each row in `embeddings.bin` was built from
the string `"[<department>] <question>\n<answer>"`. The `[dept]` prefix is a
retrieval-quality hack (rescues short titles whose context lives only in the
department field). The Flutter side does **not** need to replicate this on
the query — queries are embedded as-is, raw.

---

## 3. Model I/O contract

Model: `BAAI/bge-small-zh-v1.5`, exported via optimum, opset 17.

**Inputs** (both `int64`, batch dim required):

| name           | shape      | notes                             |
|----------------|------------|-----------------------------------|
| `input_ids`    | [1, L]     | WordPiece token ids               |
| `attention_mask` | [1, L]   | 1 for real tokens, 0 for padding  |

No `token_type_ids` — the export intentionally omits it (bge uses all zeros,
and the graph is traced accordingly).

**Outputs** (both `float32`):

| name                | shape      | notes                              |
|---------------------|------------|------------------------------------|
| `token_embeddings`  | [1, L, 512] | pre-pool token embeddings — ignore |
| `sentence_embedding`| [1, 512]   | **this is what you want**           |

**Critical**: `sentence_embedding` already has CLS pooling **and L2
normalisation baked into the graph**. You do **not** need to pool or
normalise again on the Flutter side. This was verified with
`reference/verify_onnx.py`: cosine similarity vs. PyTorch is 1.000000 on
real Chinese queries.

**Tokenizer**: WordPiece, vocab size 21 128, lowercasing enabled, max input
512 (truncate longer queries). `tokenizer.json` is the recommended source;
`vocab.txt` is a fallback for libraries that only understand that format.

---

## 4. Retrieval algorithm (port of `reference/retrieve.py`)

```dart
/// Pseudo-code — adapt to TownPass's GetX service pattern.
class FaqRagService {
  late Float32List embeddings;        // length = 8121 * 512
  late List<Metadata> metadata;       // length = 8121
  late OrtSession session;            // model.onnx
  late BertTokenizer tokenizer;       // from tokenizer.json

  static const int dim = 512;
  static const int count = 8121;
  static const double highConf = 0.73;
  static const double lowConf = 0.65;

  Future<void> loadAssets() async {
    // mmap-style read: load embeddings.bin as Float32List directly
    final raw = await rootBundle.load('assets/faq_rag/embeddings.bin');
    embeddings = raw.buffer.asFloat32List();
    assert(embeddings.length == count * dim);

    final jsonStr = await rootBundle.loadString('assets/faq_rag/metadata.json');
    metadata = (jsonDecode(jsonStr) as List)
        .map((e) => Metadata.fromJson(e)).toList();
    // model.onnx + tokenizer loaded by flutter_edge_ai / onnxruntime
  }

  SearchResult search(String query, {int k = 5}) {
    // 1. Tokenise + run ONNX
    final ids = tokenizer.encode(query);                      // List<int>
    final mask = List<int>.filled(ids.length, 1);
    final out = session.run({
      'input_ids':      Int64List.fromList(ids),
      'attention_mask': Int64List.fromList(mask),
    });
    final q = out['sentence_embedding'] as Float32List;       // [512]

    // 2. Cosine against matrix (both sides L2-normalised ⇒ dot product)
    final scores = Float32List(count);
    for (var i = 0; i < count; i++) {
      double s = 0;
      final base = i * dim;
      for (var d = 0; d < dim; d++) {
        s += embeddings[base + d] * q[d];
      }
      scores[i] = s;
    }

    // 3. Top-k via partial heap or just sort (8121 is small)
    final topK = List<int>.generate(count, (i) => i)
      ..sort((a, b) => scores[b].compareTo(scores[a]));
    final hits = topK.take(k).map((i) => Hit(
      score: scores[i],
      metadata: metadata[i],
    )).toList();

    // 4. Confidence guard
    final top = hits.first.score;
    if (top >= highConf) return SearchResult.high(hits);
    if (top >= lowConf)  return SearchResult.low(hits, caveat: _lowConfMsg);
    return SearchResult.none(_noMatchMsg);
  }
}
```

### Confidence guard

The absolute thresholds were empirically tuned on bge-small-zh output
distribution for this corpus. They must stay as-is unless the index is
rebuilt with a different model.

```
top_score ≥ 0.73  → high    show results normally
top_score ≥ 0.65  → low     show results + "參考答案，建議撥 1999 確認"
top_score <  0.65 → none    hide results + "找不到相關 FAQ，請撥 1999"
```

Full messages (use verbatim):

- `NO_MATCH_MESSAGE`:
  `抱歉，目前沒有找到相關的台北市府 FAQ。如需進一步協助，請撥打市民熱線 1999（外縣市 02-27208889）。`
- `LOW_CONF_CAVEAT`:
  `以下是最接近的參考答案，但信心較低，建議撥打 1999 再次確認。`

### Performance budget

On a modern Android phone, expect:
- Model load: ~200 ms (one-time at app startup; do it in a service `onInit`)
- Query embed: ~30–80 ms
- Cosine + top-k: ~5–15 ms (8121 × 512 is a trivial matrix op)
- **Total per query: < 100 ms** target. If you blow past 200 ms, profile the
  cosine loop — SIMD/NEON accelerated BLAS would help but is probably
  overkill at this scale.

---

## 5. UI recommendations

### Empty-state / `confidence == none`

Show the `NO_MATCH_MESSAGE` prominently. Offer:
- a direct-dial button for 1999
- "search again" prompt

Users who type very short queries (≤ 3 chars) or obvious typos end up here.
Consider a soft "你的問題太簡短，請試試完整的說法" nudge for queries shorter
than 5 characters, before even hitting the retriever.

### Low-confidence band (`confidence == low`)

Show the `LOW_CONF_CAVEAT` banner above the results. Visually distinct
(yellow/amber) so the user knows these aren't authoritative.

### High-confidence (`confidence == high`)

Show the top-1 FAQ answer prominently. Offer top-3 as "相關問答" cards
below. Always display:
- department (`e.department`) as a chip
- source attribution: "資料來源：[department]" at the bottom of each answer

### Known-false-positive "台北-only" trap

`新北市戶籍遷入` currently returns `high` confidence because the FAQ
corpus is Taipei-only, but a 新北 query is semantically very close to
台北 content. Mitigate at the UI layer with a persistent disclaimer:
**"本服務僅涵蓋臺北市政府 FAQ"** — either in the app header or on the
search page.

---

## 6. Smoke tests

`smoke_tests.json` contains 19 query→expected-result fixtures. The Flutter
side should run these after integration and verify:

- `expected_top_id` matches the actual top-1 FAQ id (by string equality)
- `expected_confidence` matches the band reported
- `expected_top_score` matches within ±0.005 tolerance (ARM vs x86 float
  summation order can drift at the 1e-4 level — that's fine)

Categories:

| category   | count | expected behaviour                          |
|------------|-------|---------------------------------------------|
| `high_conf`| 9     | `confidence == "high"`, top-1 id matches    |
| `low_conf` | 2     | `confidence == "low"`, caveat shown         |
| `no_match` | 6     | `confidence == "none"`, no results shown    |
| `known_fp` | 2     | documented miss-categorisations (see §5)    |

Minimal Dart harness:

```dart
test('smoke tests from Python reference', () async {
  final svc = Get.find<FaqRagService>();
  final fixtures = jsonDecode(
    await rootBundle.loadString('assets/faq_rag/smoke_tests.json'),
  ) as List;
  for (final f in fixtures) {
    final result = svc.search(f['query'] as String);
    expect(result.confidence, f['expected_confidence'],
      reason: 'query=${f['query']}');
    if (f['expected_top_id'] != null) {
      expect(result.hits.first.metadata.id, f['expected_top_id']);
      expect(result.hits.first.score,
        closeTo(f['expected_top_score'] as double, 0.005));
    }
  }
});
```

---

## 7. Known limitations

| # | Case | Symptom | Mitigation |
|---|------|---------|------------|
| 1 | **Chinese typos** (`接踵` vs `接種`) | Returns `no_match` even when a trivially-fixable typo would match a real FAQ. BGE's Chinese vocab has zero typo tolerance. | Add BM25 keyword fallback + edit-distance helper. ~100 lines of Dart. Future enhancement. |
| 2 | **Very short queries** (`疫苗`, `繳費`) | Returns `no_match` because 2–3 char queries carry too little context for semantic retrieval. | UI nudge: "請輸入完整的問題". |
| 3 | **Semantic negation** (`外國人可以免費看動物園嗎`) | Returns `high` confidence pointing at the price-list FAQ — but the actual answer says "優待票 50 元", which is semantically opposite to "免費". | Needs BM25 hybrid or a secondary negation-aware reranker. Not solvable by raising the threshold alone. |
| 4 | **Out-of-scope but Taipei-adjacent** (`新北市戶籍遷入`, `基隆港歷史`) | 新北 passes `high` because Taipei 戶籍 FAQs score ~0.75; 基隆 correctly falls to `no_match`. | UI disclaimer "本服務僅限臺北市資料". |
| 5 | **English queries** | Model is zh-TW/zh-CN trained; English retrieval is unreliable. Not a current requirement. | Document, don't fix. |

All five are documented here precisely so the Flutter UX can degrade
gracefully instead of silently misleading users.

---

## 8. Dependency recommendations

### Primary: `flutter_edge_ai`

- Supports Android, iOS, macOS, Linux, Windows, Web, pure dart:ffi.
- Built-in BERT WordPiece tokenizer loader (feed it `vocab.txt` +
  `tokenizer_config.json`).
- Active maintenance as of 2026.

Check that it accepts models with two inputs and two outputs; the common
case is single-output encoders, so you may need to specify the output
name (`sentence_embedding`) when instantiating.

### Fallback: raw `onnxruntime` + custom tokenizer

If `flutter_edge_ai` doesn't fit (version conflict with existing TownPass
deps, licence incompatibility, etc.):

- `onnxruntime` package for inference.
- Tokenizer: either port HuggingFace Rust tokenizers via
  `flutter_rust_bridge`, OR write a minimal BERT WordPiece tokenizer in
  Dart (~200 lines; the hard part is the exact UNK fallback behaviour).

Avoid pure-Dart SentencePiece libraries — bge uses WordPiece, not SP.

### Flutter SDK compatibility

The repo pins Flutter 3.47.6 / Dart 3.13.5 via FVM (`.fvmrc`). Before
adding either package, verify its lower bound is ≤ 3.13.0 (per
`pubspec.yaml` SDK constraint). Record any version pin in the plan
following AGENTS.md §3.

---

## 9. Integration checklist (for the Flutter agent)

Per AGENTS.md §2, create a feature branch (`feat/faq-rag`) and make one
coherent commit per logical step. Suggested sequence:

1. **Deps** — add `flutter_edge_ai` (or chosen ONNX stack) to `pubspec.yaml`.
   Run `fvm flutter pub get`. Verify versions match the pinned SDK.
2. **Assets** — copy `rag_handoff/assets/` into `TownPass/assets/faq_rag/`;
   register the directory in `pubspec.yaml`. `fvm flutter pub get` again.
3. **Service** — `lib/service/faq_rag_service.dart` following the pattern
   in §4. Register via `Get.put(FaqRagService(), permanent: true)` in the
   existing service init block (check `lib/main.dart`).
4. **Page** — `lib/page/faq/` with `faq_view_controller.dart`,
   `faq_view.dart`, `faq_binding.dart`. Use `TPColors`, `TPText`,
   `TPAppBar`, `TPButton` per AGENTS.md §4.
5. **Route** — register the new page in the existing `TPRoute` / `GetPage`
   list. Check for existing routing conventions before inventing one.
6. **Smoke test** — wire `smoke_tests.json` into a Dart test. Red → fix →
   green before UI polishing.
7. **Verify on device** — `fvm flutter run` on an Android emulator and (if
   available) iOS. The AGENTS.md is explicit: Android passing does not
   imply iOS passing.
8. **Plan doc** — record decisions and migration impact in
   `docs/rag-integration.md` (follow the repo's docs/ convention) before
   opening a PR.

**Do not** force-push, publish to pub.dev, modify `.fvmrc`, or touch
Gradle / AGP / NDK versions as part of this work — strictly scoped per
AGENTS.md.

---

## 10. Contact points for the receiving agent

- Re-running the index: `build_rag_dataset.py` → `build_index.py` →
  `python -m optimum.exporters.onnx ...`. All three scripts are in
  `reference/`. Only matters if the FAQ corpus changes.
- Model swap: edit `MODEL_NAME` in `build_index.py` and re-run. The
  confidence thresholds (0.73 / 0.65) are specific to bge-small-zh-v1.5 —
  recalibrate against a labelled query set if changing models.
- Parity check: `verify_onnx.py` exists as a regression guard. Any ONNX
  re-export must still produce cos ≈ 1.000 vs. the reference
  SentenceTransformer encoding for Chinese inputs.

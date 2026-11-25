"""Every Q&A source is complete (portal_assistant/scripts/check_qa_source.py, rules section 11,
2026-11-25): the checks that need neither the network nor the e5 server run for every source,
and each check is shown to catch the step it guards (a fake source missing that step).

The runtime-fetch source's content and the e5 score checks run with the script itself
(python -X utf8 portal_assistant/scripts/check_qa_source.py --all, with the embedding server);
here the score checks run on made-up vectors."""
import copy
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import check_qa_source as cq  # noqa: E402

# data/qa_baseline.json: the sources of 2026-11-25 and the numbers measured then (ceilings that
# may only go down). Locked: a new source must not join it to skip the new-source rules.
BASELINE_SHA256 = "39976e0ee900dddfe2462d43999f9376e06f086d9fc8826e2c412b53df286472"
LANGUAGES = cq.LANGUAGES


def baseline_digest():
    data = json.loads(cq.BASELINE.read_text(encoding="utf-8"))
    return hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


FAKE_ITEMS = [{"id": f"fake:{i}", "question": f"範例假問題第{i}號：測試服務的櫃台{i}點有人嗎", "answer": f"範例答案{i}。",
               "department": "測試團隊", "category": "測試", "source": "fake_qa",
               "published_at": "2015-01-02" if i == 0 else f"2026-01-{i + 1:02d}"} for i in range(12)]


def fake_dev():
    return {"source": "fake_qa", "written_by": "test",
            "positives": [{"text": f"想問假服務的第{i}件事情怎麼辦理"} for i in range(10)],
            "negatives": [{"text": f"跟假服務無關的閒聊第{i}句話"} for i in range(10)]}


def fake_data(offline=True, **changes):
    """Real registry + a complete fake team-written source (bundled-file, generic parser)."""
    data = cq.Data(offline=offline)
    data.registry = copy.deepcopy(data.registry)
    source = {"id": "fake_qa", "id_prefix": "fake:", "kind": "bundled-file", "file": "qa_fake_qa.json",
              "parser": "generic", "department": "測試團隊",
              "names": {language: f"假問答 {language}" for language in LANGUAGES},
              "source_note": {language: f"來源：假問答 {language}" for language in LANGUAGES},
              "answer_note": {language: "" for language in LANGUAGES},
              "open_capability": None,
              "license": {"name": "Team-written (this project)", "url": None, "store_text_in_repo": True},
              "limits": {"max_bytes": 65536, "max_items": 100}}
    source.update(changes.pop("source", {}))
    for key in [k for k, v in source.items() if v == "<drop>"]:
        del source[key]
    data.registry["sources"].append(source)
    data.sources = data.registry["sources"]
    data.by_id = {s.get("id"): s for s in data.sources}
    data.items_override = {"fake_qa": changes.pop("items", FAKE_ITEMS), "city_faq": [
        {"id": "1", "question": "市府的某個問題", "answer": "答", "department": "某局", "category": "x"}],
        "townpass_qna": []}
    data.dev_override = {"fake_qa": changes.pop("dev", fake_dev())}
    data._eval = changes.pop("evaluation", {"fake set": ["一句完全不同的評估句子"]})
    for key, value in changes.items():
        setattr(data, key, value)
    return data, source


# The fake source's bundled file lives in a folder of its own (never in the repository).
FILES = tempfile.TemporaryDirectory()
(pathlib.Path(FILES.name) / "qa_fake_qa.json").write_text(json.dumps({"items": FAKE_ITEMS}, ensure_ascii=False),
                                                          encoding="utf-8")


def problems(data, sid="fake_qa", scorer=None):
    report = cq.Report()
    cq.check_registry(data, report)
    source = data.by_id[sid]
    with mock.patch.object(cq, "ASSETS", pathlib.Path(FILES.name)):
        cq.check_schema(data, source, report)
    cq.check_license(data, source, report)
    entries = cq.check_content(data, source, report)
    cq.check_dev(data, source, report, entries)
    if scorer is not None:
        cq.check_scores(data, source, report, scorer)
    return [(kind, message) for _, kind, message in report.problems], report


class CompletenessTests(unittest.TestCase):
    def test_every_source_is_complete_offline(self):
        report = cq.check([s["id"] for s in cq.Data().sources], data=cq.Data(offline=True), scores=False)
        self.assertEqual(report.problems, [])

    def test_the_baseline_never_grows(self):
        self.assertEqual(baseline_digest(), BASELINE_SHA256)
        self.assertEqual(sorted(json.loads(cq.BASELINE.read_text(encoding="utf-8"))["sources"]),
                         ["city_faq", "townpass_qna"])

    def test_pages_of_unstorable_sources_are_never_pre_translated(self):
        # Owner 2026-11-25 (rules section 11): the TownPass Q&A page shows text of a repository
        # without a licence. Detected by page path and source, never by quoting the text.
        import extract_service_strings as ess
        capabilities = {c["id"]: c for c in json.loads(
            (cq.ASSETS / "capabilities.json").read_text(encoding="utf-8"))["capabilities"]}
        expected = sorted({capabilities[s["open_capability"]]["navigation"]["path"].rstrip("/")
                           for s in cq.Data().sources
                           if s.get("open_capability") and (s.get("license") or {}).get("store_text_in_repo") is False})
        self.assertIn("/qna", expected)
        self.assertEqual(ess.excluded_paths(), expected)
        for path in ("/qna", "/qna/", "/qna/categories", ess.DEFAULT_ORIGIN + "/qna/categories?x=1"):
            self.assertTrue(ess.is_excluded(path), path)
        for path in ("/qnaire", "/fee-payment/", "/"):
            self.assertFalse(ess.is_excluded(path), path)
        self.assertFalse([p for p in ess.page_paths() if ess.is_excluded(p)])
        strings = json.loads((ROOT / "app" / "assets" / "i18n" / "service_strings.json").read_text(encoding="utf-8"))
        self.assertEqual(strings.get("excluded_pages"), expected,
                         "service_strings.json was not written by extract_service_strings.py with the exclusion")

    def test_runtime_text_is_not_stored_in_the_project(self):
        # With this machine's runtime cache of the TownPass Q&A (outside the repository; written
        # by the backend), none of its texts may appear in portal_assistant/ or .claude/.
        import qna
        cache = qna.default_cache()
        try:
            document = json.loads(cache.read_text(encoding="utf-8"))["document"]
        except (OSError, ValueError, KeyError):
            self.skipTest("no TownPass Q&A cache on this machine (the backend writes it after a download)")
        entries = qna.parse(document)
        if not entries:
            self.skipTest("the cached TownPass Q&A has no items")
        data = cq.Data(offline=True)
        report = cq.Report()
        cq.check_not_stored(data, data.by_id["townpass_qna"], entries, report)
        self.assertEqual([m for _, _, m in report.problems], [])

    def test_qa_holdout_is_sealed(self):
        report = cq.Report()
        cq.check_holdout_seal(report)
        self.assertEqual(report.problems, [])
        result = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts" / "seal_holdout.py"), "--set", "qa",
                                 "--check"], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_skill_entries_match_the_skills(self):
        result = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts" / "sync_skill.py"), "--check"],
                                capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout)
        for name in ("townpass-add-service", "townpass-add-qa"):
            self.assertTrue((ROOT / "skills" / name / "SKILL.md").exists(), name)
            self.assertTrue((ROOT / "skills" / name / "MANUAL_TEST_TEMPLATE.md").exists(), name)
        # The two skills point at each other (a new service with its own Q&A goes on to add-qa).
        service = (ROOT / "skills" / "townpass-add-service" / "SKILL.md").read_text(encoding="utf-8")
        qa = (ROOT / "skills" / "townpass-add-qa" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("townpass-add-qa", service)
        self.assertIn("townpass-add-service", qa)


class CatchesTests(unittest.TestCase):
    """A fake new source with one step missing fails with that step named."""

    def assert_caught(self, data, kind, words, sid="fake_qa", scorer=None):
        found, _ = problems(data, sid, scorer)
        self.assertTrue(any(k == kind and words in m for k, m in found), found)

    def test_the_complete_fake_passes(self):
        found, _ = problems(fake_data()[0])
        self.assertEqual(found, [])

    def test_schema(self):
        self.assert_caught(fake_data(source={"kind": "web"})[0], "schema", "kind")
        self.assert_caught(fake_data(source={"parser": "magic"})[0], "schema", "parser")
        data, source = fake_data()
        del source["names"]["ja"]
        self.assert_caught(data, "schema", "names has no ja")
        self.assert_caught(fake_data(source={"source_note": {"zh": "x"}})[0], "schema", "source_note has no en")
        self.assert_caught(fake_data(source={"open_capability": "noSuchPage"})[0], "schema", "open_capability")
        self.assert_caught(fake_data(source={"department": ""})[0], "schema", "department")
        self.assert_caught(fake_data(source={"names": {lang: "TODO" for lang in LANGUAGES}})[0], "schema", "TODO")
        self.assert_caught(fake_data(source={"file": "fake.json"})[0], "schema", "qa_<name>.json")
        self.assert_caught(fake_data(source={"file": "qa_not_there.json"})[0], "schema", "not in")
        runtime = {"kind": "runtime-fetch", "origin": "https://example.org", "path": "/qa.json", "file": "<drop>",
                   "license": {"name": "unknown", "url": None, "store_text_in_repo": False}}
        self.assert_caught(fake_data(source=runtime)[0], "schema", "service_origins.json")
        self.assert_caught(fake_data(source={**runtime, "origin": "default", "path": "https://x.org/qa.json"})[0],
                           "schema", "path")
        self.assert_caught(fake_data(source={**runtime, "origin": "default", "limits": {}})[0], "schema", "max_bytes")

    def test_license(self):
        self.assert_caught(fake_data(source={"license": "<drop>"})[0], "license", "no license")
        self.assert_caught(fake_data(source={"license": {"name": "", "url": None, "store_text_in_repo": True}})[0],
                           "license", "name")
        self.assert_caught(fake_data(source={"license": {"name": "x", "store_text_in_repo": True}})[0], "license", "url")
        self.assert_caught(fake_data(source={"license": {"name": "x", "url": None, "store_text_in_repo": False}})[0],
                           "license", "runtime-fetch")
        self.assert_caught(fake_data(source={"license": {"name": "unknown", "url": None,
                                                         "store_text_in_repo": True}})[0], "license", "only")
        # Open data (not team-written) needs its attribution: provider, dataset, link, check date.
        open_data = {"name": "政府資料開放授權條款第1版", "url": "https://data.gov.tw/license", "store_text_in_repo": True,
                     "provider": "某機關", "dataset_title": "某資料集", "dataset_url": "https://example.org/d",
                     "verified": "2026-11-25"}
        self.assertEqual(problems(fake_data(source={"license": open_data})[0])[0], [])
        for key in ("provider", "dataset_title", "dataset_url", "verified"):
            self.assert_caught(fake_data(source={"license": {k: v for k, v in open_data.items() if k != key}})[0],
                               "license", f"license.{key}")

    def test_license_text_not_stored(self):
        data, source = fake_data(source={"license": {"name": "None", "url": None, "store_text_in_repo": False}})
        with tempfile.TemporaryDirectory() as directory:
            stored = pathlib.Path(directory) / "fixture.json"
            stored.write_text(json.dumps({"q": FAKE_ITEMS[3]["question"]}, ensure_ascii=False), encoding="utf-8")
            with mock.patch.object(cq, "stored_files", return_value=[stored]), \
                    mock.patch.object(cq, "REPO", pathlib.Path(directory)):
                found, _ = problems(data)
        self.assertTrue(any(k == "license" and "fixture.json" in m for k, m in found), found)
        self.assertFalse(any(FAKE_ITEMS[3]["question"] in m for _, m in found))  # never the text itself

    def test_prefix(self):
        self.assert_caught(fake_data(source={"id_prefix": "qna:"})[0], "prefix", "also used")
        self.assert_caught(fake_data(source={"id_prefix": "qna:x:"})[0], "prefix", "start of")
        self.assert_caught(fake_data(source={"id_prefix": ""})[0], "prefix", "exactly one")
        self.assert_caught(fake_data(source={"id_prefix": "Fake"})[0], "prefix", "ending in ':'")

    def test_duplicates_and_overlap(self):
        data, _ = fake_data()
        data.items_override["city_faq"] = [{"id": str(i), "question": e["question"] + "？", "answer": "答",
                                            "department": "某局", "category": "x"} for i, e in enumerate(FAKE_ITEMS[:8])]
        self.assert_caught(data, "content", "repeat another source")
        near = [dict(FAKE_ITEMS[0], question="一句完全不同評估的句子")] + FAKE_ITEMS[1:]
        found, _ = problems(fake_data(items=near)[0])
        # The source's own item is named (so it can be reworded), never the evaluation sentence.
        self.assertTrue(any(k == "content" and "fake set" in m and "fake:0" in m for k, m in found), found)
        self.assertFalse(any("一句完全不同的評估句子" in m for _, m in found))
        # A source whose text may not be stored is named by item id only.
        data, _ = fake_data(items=near, source={"license": {"name": "None", "url": None, "store_text_in_repo": False},
                                                "kind": "runtime-fetch", "origin": "default", "path": "/qa.json",
                                                "file": "<drop>"})
        with mock.patch.object(cq, "stored_files", return_value=[]):
            found, _ = problems(data)
        message = next(m for k, m in found if k == "content" and "fake set" in m)
        self.assertIn("fake:0", message)
        self.assertNotIn("一句完全不同評估的句子", message)
        self.assert_caught(fake_data(items=[])[0], "content", "no item")

    def test_dev(self):
        self.assert_caught(fake_data(dev=None)[0], "dev", "missing")
        dev = fake_dev()
        dev["positives"] = dev["positives"][:9]
        self.assert_caught(fake_data(dev=dev)[0], "dev", "9 positives")
        dev = fake_dev()
        dev["negatives"] = dev["negatives"][:3]
        self.assert_caught(fake_data(dev=dev)[0], "dev", "3 negatives")
        dev = fake_dev()
        dev["positives"][0]["text"] = "一句完全不同的評估句子吧"
        found, _ = problems(fake_data(dev=dev)[0])
        self.assertTrue(any(k == "dev" and "fake set" in m for k, m in found), found)
        dev = fake_dev()
        dev["positives"][0]["expected_ids"] = ["fake:99"]
        self.assert_caught(fake_data(dev=dev)[0], "dev", "fake:99")
        dev = fake_dev()
        dev["written_by"] = ""
        self.assert_caught(fake_data(dev=dev)[0], "dev", "written_by")
        dev = fake_dev()
        dev["positives"][0]["text"] = FAKE_ITEMS[2]["question"]
        data, _ = fake_data(dev=dev, source={"license": {"name": "None", "url": None, "store_text_in_repo": False},
                                             "kind": "runtime-fetch", "origin": "default", "path": "/qa.json",
                                             "file": "<drop>"})
        with mock.patch.object(cq, "stored_files", return_value=[]):
            self.assert_caught(data, "dev", "copy of this source's text")

    def test_scores(self):
        # Made-up 3-d vectors: the fake source's items at x, the city FAQ at y.
        data, _ = fake_data()
        positives = [p["text"] for p in fake_dev()["positives"]]
        negatives = [n["text"] for n in fake_dev()["negatives"]]
        vectors = {"fake_qa": [[1.0, 0.0, 0.0]] * len(FAKE_ITEMS), "city_faq": [[0.0, 1.0, 0.0]]}
        entries = {"fake_qa": FAKE_ITEMS, "city_faq": data.items_override["city_faq"]}

        def scorer(where):
            return cq.Scorer(data, lambda texts: [where(t) for t in texts], vectors, entries)
        good = scorer(lambda t: [1.0, 0.0, 0.0] if t in positives else [0.0, 0.0, 1.0])
        found, _ = problems(data, scorer=good)
        self.assertEqual(found, [])
        wrong = scorer(lambda t: [0.0, 1.0, 0.0] if t == positives[0] else
                       [1.0, 0.0, 0.0] if t in positives else [0.0, 0.0, 1.0])
        self.assert_caught(data, "scores", "1 positive(s)", scorer=wrong)
        high = scorer(lambda t: [0.95, 0.31, 0.0] if t == negatives[0] else
                      [1.0, 0.0, 0.0] if t in positives else [0.0, 0.0, 1.0])
        self.assert_caught(data, "scores", "negative(s) score", scorer=high)
        grabs = scorer(lambda t: [1.0, 0.0, 0.0] if t in positives or "評估" in t else [0.0, 0.0, 1.0])
        found, _ = problems(data, scorer=grabs)
        self.assertTrue(any(k == "scores" and "fake set" in m and "this source's answer first" in m
                            for k, m in found), found)
        data.dev_override["fake_qa"]["accepted_eval_changes"] = {"fake set": 1}
        found, _ = problems(data, scorer=grabs)
        self.assertFalse(any("this source's answer first" in m for _, m in found), found)

    def test_order(self):
        data, source = fake_data()
        report = cq.Report()
        cq.check_order(data, source, report, FAKE_ITEMS)
        self.assertEqual(report.problems, [])
        # A request that no service handles is answered from the source: the check notices.
        with mock.patch.object(cq, "SERVICE_FIRST", ("今天心情真好嗎",)), mock.patch("workflow.INTENT_FALLBACK", False):
            cq.check_order(data, source, report, FAKE_ITEMS)
        self.assertTrue(any(kind == "order" for _, kind, _ in report.problems), report.problems)

    def test_holdout_and_manual(self):
        data, source = fake_data()
        report = cq.Report()
        cq.check_holdout(data, source, report)
        cq.check_manual(data, source, report)
        kinds = [kind for _, kind, _ in report.problems]
        self.assertIn("holdout", kinds)
        self.assertIn("manual", kinds)
        with tempfile.TemporaryDirectory() as directory:
            changed = pathlib.Path(directory) / "eval_new_qa_holdout.json"
            changed.write_text('{"meta": {"sealed": "x"}, "items": []}', encoding="utf-8")
            with mock.patch.object(cq, "HOLDOUT", changed):
                report = cq.Report()
                cq.check_holdout_seal(report)
        self.assertTrue(any("differs from its last seal" in m for _, _, m in report.problems), report.problems)

    def test_stale_items_are_listed_not_failed(self):
        import datetime
        data, source = fake_data()
        report = cq.Report()
        cq.check_stale(data, source, report, FAKE_ITEMS, today=datetime.date(2026, 11, 25))
        self.assertEqual(report.problems, [])
        self.assertTrue(any("fake:0 2015-01-02" in note and "1 of 12" in note for note in report.notes), report.notes)
        # A team-written (bundled-file) item without published_at fails; elsewhere it is a note (drill 2026-11-25).
        undated = [{k: v for k, v in e.items() if k != "published_at"} for e in FAKE_ITEMS[:2]] + FAKE_ITEMS[2:]
        report = cq.Report()
        cq.check_stale(data, source, report, undated, today=datetime.date(2026, 11, 25))
        self.assertTrue(any(kind == "content" and "published_at" in m for _, kind, m in report.problems), report.problems)
        report = cq.Report()
        cq.check_stale(data, dict(source, kind="runtime-fetch"), report, undated, today=datetime.date(2026, 11, 25))
        self.assertEqual(report.problems, [])

    def test_unknown_fields_fail(self):
        # Order and thresholds are not data: a field the code ignores must not pass unnoticed (drill 2026-11-25).
        self.assert_caught(fake_data(source={"priority": 1})[0], "schema", "unknown field")
        self.assertEqual(problems(fake_data(source={"_comment": "notes are fine"})[0])[0], [])

    def test_existing_sources_keep_their_ceilings(self):
        data = cq.Data(offline=True)
        self.assertFalse(data.is_new("city_faq"))
        self.assertFalse(data.is_new("townpass_qna"))
        self.assertTrue(data.is_new("fake_qa"))


if __name__ == "__main__":
    unittest.main()

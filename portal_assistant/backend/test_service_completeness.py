"""Every service is complete (portal_assistant/scripts/check_service.py, rules section 10,
2026-11-24): the checks that need no network run for every capability, and each check is
shown to catch the step it guards (a fake service missing that step).

The slower or online parts run with the script itself: --routes (the site's route table),
--strings (service page texts, Playwright) and --collisions (test_rule_collisions.py, which
also runs in this suite on its own)."""
import copy
import hashlib
import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import check_service  # noqa: E402

DATA = check_service.Data()

# The services and guide pages of 2026-11-24 (data/service_baseline.json) keep their older
# rules; the list may never grow, or a new service could skip the full rules by joining it.
BASELINE_SHA256 = "13629ff048e848e4f69aeba29e6f397b45329fff76a7a87a2eb8ac765778878c"


def baseline_digest():
    data = json.loads(check_service.BASELINE.read_text(encoding="utf-8"))
    text = "\n".join(sorted(data["services"])) + "\n--\n" + "\n".join(sorted(data["guide_pages"]))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def fake_service(data, service="testFake", **changes):
    """A complete new web service (all checks pass), copied from fees.water's shape."""
    data = copy.deepcopy(data)
    data.by_id = {e["id"]: e for e in data.entries}
    entry = {"id": service, "title": "測試服務", "need": "想試試看一個不存在的測試服務，確認檢查會不會漏掉步驟。",
             "category": "城市服務", "group": "apply", "keywords": ["測試服務"], "features": [], "enabled": True,
             "reason": "", "mode": "demo",
             "navigation": {"type": "web", "path": "/test-fake/", "parents": [], "query": {}}}
    entry.update(changes.pop("entry", {}))
    data.entries.append(entry)
    data.by_id[service] = entry
    data.i18n[service] = {language: {"title": f"Test {language}", "keywords": [f"test {language}"],
                                     "need": f"A test need in {language} that is long enough."}
                          for language in check_service.LANGUAGES}
    data.examples[service] = {"zh": [f"測試句子第{i}句，完全不會和評估句重疊的內容" for i in range(8)],
                              **{language: [f"{language} sample {i} qqq zzz" for i in range(3)]
                                 for language in check_service.LANGUAGES}}
    for key, value in changes.items():
        setattr(data, key, value)
    data._eval = {"fake set": ["一句完全不同的評估句"]}
    return data


def problems(data, service="testFake", evaluation=False):
    report = check_service.Report()
    check_service.check_catalog(data, service, report)
    check_service.check_languages(data, service, report)
    check_service.check_examples(data, service, report)
    check_service.check_navigation(data, service, report)
    check_service.check_guide(data, service, report)
    if evaluation:
        check_service.check_evaluation(data, service, report)
    return [(kind, message) for _, kind, message in report.problems]


class CompletenessTests(unittest.TestCase):
    def test_every_service_is_complete(self):
        report = check_service.check([e["id"] for e in DATA.entries], data=DATA)
        self.assertEqual(report.problems, [])

    def test_the_baseline_never_grows(self):
        self.assertEqual(baseline_digest(), BASELINE_SHA256)
        self.assertTrue(DATA.baseline <= set(DATA.by_id) | DATA.baseline)  # removed services may stay listed

    def test_guide_lists_match_the_guide_files(self):
        import sync_guide_lists
        files, problems_found, _ = sync_guide_lists.expected()
        self.assertEqual(problems_found, [])
        for path, text in files.items():
            self.assertEqual(path.read_text(encoding="utf-8"), text, f"{path.name}: run sync_guide_lists.py")

    def test_pre_translations_are_complete(self):
        # App strings (host lib/ and mock data) and guide strings; the service pages need a
        # browser and the network (check_service.py --strings).
        for script in ("extract_app_strings.py", "extract_guide_strings.py"):
            result = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts" / script), "--check"],
                                    capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(result.returncode, 0, result.stdout[-2000:])

    def test_skill_entry_matches_the_skill(self):
        # .claude/skills/<name>/SKILL.md (Claude Code) follows portal_assistant/skills/<name>/SKILL.md.
        result = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts" / "sync_skill.py"), "--check"],
                                capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((ROOT / "skills" / "townpass-add-service" / "MANUAL_TEST_TEMPLATE.md").exists())

    def test_new_service_holdout_is_sealed(self):
        report = check_service.Report()
        check_service.check_holdout_seal(report)
        self.assertEqual(report.problems, [])


class DataFieldTests(unittest.TestCase):
    """The constants that became data (2026-11-24, stage 2) read as before."""

    def test_service_origins(self):
        import origins
        self.assertIn(origins.default(), origins.allowed())
        import qna
        import server
        self.assertEqual(qna.DEFAULT_URL, origins.default() + "/mock/qna_list.json")
        self.assertEqual(server.CATALOG_URL, origins.default() + "/mock/library/library_book_list.json")

    def test_frequent_default_and_list_last(self):
        from registry import Registry
        registry = Registry()
        self.assertEqual(registry.frequent_default(), ("fees.water", "library", "reservation", "fees.parking"))
        self.assertEqual(registry.list_last(), {"app.home", "app.services", "start_page", "pinned"})

    def test_emergency_forms(self):
        from registry import Registry
        default, forms = Registry().emergency_forms("fire")
        self.assertEqual(default["id"], "disasterReport.form.D-4-1")
        self.assertEqual([f["id"] for f in forms], [f"disasterReport.form.D-4-{i}" for i in range(1, 5)])
        self.assertEqual(Registry().emergency_forms("violence"), (None, []))

    def test_continue_to_default(self):
        from guide import GuidePlanner
        pages = GuidePlanner().pages
        self.assertEqual({page for page, spec in pages.items() if spec.get("continue_to_default")},
                         {"disaster_report", "fees", "district_office", "citizen_report", "police_report"})


class CatchesTests(unittest.TestCase):
    """A fake new service with one step missing fails with that step named."""

    def assert_caught(self, data, kind, words, evaluation=False, service="testFake"):
        found = problems(data, service, evaluation=evaluation)
        self.assertTrue(any(k == kind and words in m for k, m in found), found)

    def test_the_complete_fake_passes(self):
        self.assertEqual(problems(fake_service(DATA)), [])

    def test_catalog(self):
        self.assert_caught(fake_service(DATA, entry={"need": "TODO: 寫 need"}), "catalog", "TODO")
        self.assert_caught(fake_service(DATA, entry={"need": "測試服務"}), "catalog", "need")
        self.assert_caught(fake_service(DATA, entry={"keywords": []}), "catalog", "keyword")
        self.assert_caught(fake_service(DATA, entry={"group": None}), "catalog", "group")
        self.assert_caught(fake_service(DATA, entry={"mode": "live"}), "catalog", "mode")
        self.assert_caught(fake_service(DATA, service="nohub.page"), "catalog", "id root", service="nohub.page")
        self.assert_caught(fake_service(DATA, service="library.fake"), "catalog", "/library-service",
                           service="library.fake")
        data = fake_service(DATA, entry={"navigation": {"type": "web", "path": "/counter-calling/c-9", "parents": [],
                                                        "query": {}}})
        self.assertTrue(any("reservation" in m for _, m in problems(data)))
        self.assert_caught(fake_service(DATA, entry={"frequent_default": 0}), "catalog", "frequent_default")
        self.assert_caught(fake_service(DATA, entry={"frequent_default": 1}), "catalog", "more than one")
        self.assert_caught(fake_service(DATA, entry={"suggest": {"order": 9, "text": {"zh": "試試"}}}), "catalog",
                           "suggest")
        self.assert_caught(fake_service(DATA, entry={"list_last": False}), "catalog", "list_last")
        self.assert_caught(fake_service(DATA, entry={"keywords": ["測試服務", "火災"]}), "catalog", "emergency word")
        self.assert_caught(fake_service(DATA, entry={"emergency": {"kind": "flood"}}), "catalog", "emergency")

    def test_languages(self):
        data = fake_service(DATA)
        del data.i18n["testFake"]["ja"]
        self.assert_caught(data, "languages", "ja")
        data = fake_service(DATA)
        data.i18n["testFake"]["vi"]["need"] = ""
        self.assert_caught(data, "languages", "vi")
        data = fake_service(DATA)
        data.i18n["testFake"]["en"]["title"] = "TODO"
        self.assert_caught(data, "languages", "TODO")

    def test_examples(self):
        data = fake_service(DATA)
        data.examples["testFake"]["zh"] = data.examples["testFake"]["zh"][:7]
        self.assert_caught(data, "examples", "Chinese")
        data = fake_service(DATA)
        data.examples["testFake"]["tl"] = []
        self.assert_caught(data, "examples", "tl")
        data = fake_service(DATA)
        data._eval = {"fake set": [data.examples["testFake"]["zh"][0] + "嗎"]}
        found = problems(data)
        self.assertTrue(any(k == "examples" and "fake set" in m for k, m in found), found)
        self.assertFalse(any("嗎" in m for _, m in found))  # never the evaluation sentence itself

    def test_navigation(self):
        self.assert_caught(fake_service(DATA, entry={"navigation": {
            "type": "web", "path": "/x/", "parents": [], "query": {}, "origin": "https://example.org"}}),
            "navigation", "service_origins.json")
        self.assert_caught(fake_service(DATA, entry={"navigation": {"type": "web", "path": "x y", "parents": [],
                                                                    "query": {}}}), "navigation", "path")
        self.assert_caught(fake_service(DATA, entry={"navigation": {"type": "native", "route": "/not_registered",
                                                                    "parents": []}}), "navigation", "not registered")
        self.assert_caught(fake_service(DATA, entry={"navigation": None}), "navigation", "type")
        self.assertEqual(problems(fake_service(DATA, entry={"navigation": {"type": "native", "route": "/feedback",
                                                                          "parents": ["/account"]}})), [])

    def test_routes(self):
        routes = {"/", "/fee-payment", "detail/:id", "/form/:id", "list", ":id"}
        self.assertTrue(check_service.path_in_routes("/fee-payment/detail/fee-6/", routes))
        self.assertTrue(check_service.path_in_routes("/form/a-1", routes))
        self.assertTrue(check_service.path_in_routes("/", routes))
        self.assertFalse(check_service.path_in_routes("/test-fake/", routes))  # not '/' + ':id' (drill)
        self.assertFalse(check_service.path_in_routes("/fee-payment/nothing/here/x", routes))

    def test_guide(self):
        data = fake_service(DATA, service="subscription.fake")
        data.guides = copy.deepcopy(data.guides)
        data.guides["subscription"]["components"][0]["title"] = "改過的標題"
        found = problems(data, service="subscription.fake")
        self.assertTrue(any(k == "guide" and "differ" in m for k, m in found), found)

    def test_evaluation(self):
        found = problems(fake_service(DATA), evaluation=True)
        for words in ("evaluate dev", "eval_i18n", "eval_colloquial_dev.json", "eval_need_dev.json",
                      "eval_new_services_holdout.json", "MANUAL_TEST_testFake.md"):
            self.assertTrue(any(k in ("evaluation", "manual") and words in m for k, m in found), (words, found))
        # Services of 2026-11-24 keep their rules.
        self.assertEqual([p for p in problems(DATA, service="fees.water", evaluation=True)], [])


if __name__ == "__main__":
    unittest.main()

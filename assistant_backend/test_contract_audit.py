"""App <-> backend contract fixes after the 2026-11-16 audit (docs/AI_CURRENT_RULES.md
sections 3, 5 and 7; D:\\TownPassAssistant\\need-impl\\contract-audit\\AUDIT.md), over real
HTTP like the App (server.make_handler). Sentences are written here."""
import json
import pathlib
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import i18n
import models
from server import make_handler
from test_catalog import FakeIndex, app
from test_models import entry


class Http:
    """The backend behind a real HTTP server; posts like AssistantService._request."""

    def __init__(self, assistant):
        self.assistant = assistant
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(assistant))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.n = 0

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def post(self, path, payload):
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(self.base + path, data=data, headers={
            "Content-Type": "application/json; charset=utf-8"})
        try:
            with urllib.request.urlopen(request, timeout=20) as reply:
                return reply.status, json.loads(reply.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def turn(self, text="", session="s", **fields):
        self.n += 1
        body = {"text": text, "request_id": f"r{self.n}", "session_id": session,
                **{key: value for key, value in fields.items() if value is not None}}
        return self.post("/v1/assistant/turns", body)


# What the App reads from a list reply (AssistantResult.fromJson): everything but the message.
LIST_FIELDS = ("kind", "resolution_id", "choices", "level", "group", "listing", "language")


def listed(reply):
    return {key: reply.get(key) for key in LIST_FIELDS}


class ContractTests(unittest.TestCase):
    def setUp(self):
        # Two semantic clues (test_catalog): 「家裡那張單子不知道怎麼處理」 lists 水費, 停車費, 看全部功能.
        self.http = Http(app(index=FakeIndex([(0.035, "fees.water"), (0.034, "fees.parking")])))
        self.addCleanup(self.http.close)

    def candidates(self, session="s"):
        status, result = self.http.turn("家裡那張單子不知道怎麼處理", session)
        self.assertEqual(status, 200)
        self.assertEqual(result["kind"], "confirm_candidates")
        self.assertEqual([c["title"] for c in result["choices"]], ["水費", "停車費", "看全部功能"])
        return result

    # ------------------------------------------------- 好／是: the same list again (item 4)

    def test_ok_after_the_catalogue_offers_the_same_catalogue(self):
        status, catalogue = self.http.turn("看全部功能")
        self.assertEqual((status, catalogue["kind"], catalogue["level"]), (200, "capability_list", 1))
        status, again = self.http.turn("好", resolution_id=catalogue["resolution_id"])
        self.assertEqual(status, 200)
        # Before: kind confirm_candidates and options without nav / group_id / subtitle, no level.
        self.assertEqual(listed(again), listed(catalogue))
        self.assertTrue(any(c.get("nav") == "more" for c in again["choices"]))
        self.assertTrue(any(c.get("group_id") == "frequent" for c in again["choices"]))
        self.assertEqual(again["message"], i18n.t("choose_one", "zh"))
        # Still answerable: 更多 from the list offered again turns the page.
        more = next(c["id"] for c in again["choices"] if c.get("nav") == "more")
        status, page = self.http.turn("", resolution_id=again["resolution_id"], choice_id=more)
        self.assertEqual((status, page["kind"], page["listing"]["offset"]), (200, "capability_list", 8))

    def test_ok_after_candidates_keeps_subtitles_and_see_everything(self):
        result = self.candidates()
        status, again = self.http.turn("是", resolution_id=result["resolution_id"])
        self.assertEqual(status, 200)
        self.assertEqual(listed(again), listed(result))
        self.assertEqual(again["choices"][-1].get("nav"), "catalog")
        self.assertTrue(all(c.get("subtitle") for c in again["choices"][:2]))

    def test_yes_in_another_language_offers_the_same_catalogue(self):
        status, catalogue = self.http.turn("See everything", language="en")
        self.assertEqual((status, catalogue["level"]), (200, 1))
        status, again = self.http.turn("yes", resolution_id=catalogue["resolution_id"], language="en")
        self.assertEqual(status, 200)
        self.assertEqual(listed(again), listed(catalogue))
        self.assertEqual(again["message"], i18n.t("choose_one", "en"))

    # ------------------------------- a number past the last option (item 3: 「N. 都不是」)

    def test_the_number_after_the_last_option_is_the_list_again_not_an_error(self):
        result = self.candidates()
        for said in ("第4個", "4", "第四個"):
            status, beyond = self.http.turn(said, resolution_id=result["resolution_id"])
            # Before: 422 「選項不在本輪候選中，請重新選擇。」
            self.assertEqual(status, 200, said)
            self.assertEqual((beyond["action"], beyond["choice_number"]), ("choice_out_of_range", 4))
            self.assertEqual(listed(beyond), listed(result))
            self.assertEqual(beyond["message"], i18n.t("beyond_list", "zh", number=4, count=3))
        # The list is still there: 第1個 opens 水費.
        status, opened = self.http.turn("第1個", resolution_id=result["resolution_id"])
        self.assertEqual((status, opened["kind"], opened["destination"]["id"]), (200, "navigate", "fees.water"))
        # A tapped option that is not there is still refused.
        result = self.candidates()
        status, _ = self.http.turn("", resolution_id=result["resolution_id"], choice_id="4")
        self.assertEqual(status, 422)

    def test_the_number_after_the_last_option_in_another_language(self):
        status, catalogue = self.http.turn("See everything", language="en")
        library = next(c["id"] for c in catalogue["choices"] if c.get("group_id") == "library" and not c.get("nav"))
        status, pages = self.http.turn("", resolution_id=catalogue["resolution_id"], choice_id=library)
        self.assertEqual((status, pages["level"]), (200, 2))
        past = len(pages["choices"]) + 1
        for said in (f"number {past}", str(past)):
            status, beyond = self.http.turn(said, resolution_id=pages["resolution_id"], language="en")
            self.assertEqual(status, 200, said)
            self.assertEqual((beyond["action"], beyond["choice_number"]), ("choice_out_of_range", past))
            self.assertEqual(listed(beyond), listed(pages))
            self.assertEqual(beyond["message"], i18n.t("beyond_list", "en", number=past, count=past - 1))

    # ------------------- typed follow-ups with the list's language (item 1: what the App sends)

    def test_follow_ups_in_the_lists_language_answer_the_list(self):
        """The guided App now sends the list's language with a typed follow-up (rules section
        5, 2026-11-16); without it the backend guessed from the letters (図書館 -> Chinese,
        batal -> English)."""
        cases = (("ja", "すべての機能を見る", "図書館", "level2"), ("ja", "すべての機能を見る", "2", "chosen"),
                 ("vi", "Xem tất cả chức năng", "trang sau", "page"), ("id", "Lihat semua fitur", "batal", "cancel"),
                 ("tl", "Tingnan lahat ng serbisyo", "kanselahin", "cancel"))
        for n, (language, chip, word, expected) in enumerate(cases):
            session = f"f{n}"
            status, catalogue = self.http.turn(chip, session, language=language)
            self.assertEqual((status, catalogue["level"]), (200, 1), language)
            status, reply = self.http.turn(word, session, resolution_id=catalogue["resolution_id"], language=language)
            self.assertEqual((status, reply["language"]), (200, language), word)
            if expected == "level2":
                self.assertEqual((reply["level"], reply["group"]), (2, "library"), word)
            elif expected == "page":
                self.assertEqual(reply["listing"]["offset"], 8, word)
            elif expected == "cancel":
                self.assertEqual(reply["action"], "cancel", word)
            else:
                self.assertIsNotNone(reply["destination"] or reply.get("level"), word)


class SupersededModelTests(unittest.TestCase):
    """Files an older App downloaded that nothing uses any more (rules section 7,
    docs/AI_MODEL_DOWNLOAD.md, 2026-11-16): the decision classifier v1 stayed on phones
    after v2 (132 MB), and 刪除模型 did not take it."""

    OLD = "townpass-decision-e5-ce-v1-q8_0.gguf"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = pathlib.Path(self.tmp.name) / "models"
        self.data = b"classifier v2 " * 100
        self.manifest = {"version": 1, "team_url": "", "files": [
            entry("classifier", "townpass-decision-e5-ce-v2-q8_0.gguf", "decision", self.data,
                  decision_model="classifier")],
            "superseded": [self.OLD, "../outside.bin", "/abs.bin", "C:\\x.bin", 7,
                           "townpass-decision-e5-ce-v2-q8_0.gguf"]}

    def old_files(self):
        self.dir.mkdir(exist_ok=True)
        (self.dir / self.OLD).write_bytes(b"v1")
        (self.dir / (self.OLD + ".part")).write_bytes(b"v")
        (self.dir / "pushed-by-adb.gguf").write_bytes(b"dev")  # a developer's own file stays
        (self.dir.parent / "outside.bin").write_bytes(b"x")  # "../outside.bin" in the list

    def downloads(self, **extra):
        return models.Downloads(self.dir, decision_model="classifier", manifest=self.manifest,
                                free_bytes=lambda: 10 << 30, **extra)

    def assertOnlyOldGone(self):
        self.assertFalse((self.dir / self.OLD).exists())
        self.assertFalse((self.dir / (self.OLD + ".part")).exists())
        self.assertTrue((self.dir / "pushed-by-adb.gguf").exists())
        self.assertTrue((self.dir.parent / "outside.bin").exists())

    def test_removed_at_start(self):
        self.old_files()
        self.downloads()
        self.assertOnlyOldGone()

    def test_removed_after_a_download_and_with_delete_over_http(self):
        from server import Assistant
        from test_server import FakeCatalog
        assistant = Assistant(FakeCatalog(), lambda *_: None)
        http = Http(assistant)
        self.addCleanup(http.close)
        served = ThreadingHTTPServer(("127.0.0.1", 0), _files({"/m/townpass-decision-e5-ce-v2-q8_0.gguf": self.data}))
        threading.Thread(target=served.serve_forever, daemon=True).start()
        self.addCleanup(served.server_close)
        self.addCleanup(served.shutdown)
        downloads = self.downloads(base_url=f"http://127.0.0.1:{served.server_port}")
        assistant.downloads = downloads
        self.old_files()  # left by an older App while this one runs
        status, _ = http.post("/v1/models/download", {"parts": ["decision"]})
        self.assertEqual(status, 200)
        downloads.wait(20)
        self.assertEqual(downloads.state, "done")
        self.assertTrue(downloads.ready("decision"))
        self.assertOnlyOldGone()
        self.old_files()
        status, _ = http.post("/v1/models/delete", {"parts": ["decision"]})
        self.assertEqual(status, 200)
        self.assertFalse(downloads.ready("decision"))
        self.assertOnlyOldGone()

    def test_only_plain_names_that_the_manifest_no_longer_lists(self):
        self.assertEqual(self.downloads().superseded(), [self.OLD])
        # Going back to v1 (its name in files again) keeps the file.
        self.manifest["files"].append(entry("v1", self.OLD, "decision", b"v1", decision_model="old"))
        self.old_files()
        self.downloads()
        self.assertTrue((self.dir / self.OLD).exists())

    def test_the_shipped_manifest_supersedes_classifier_v1(self):
        manifest = models.load_manifest()
        names = {e["name"] for e in manifest["files"]}
        self.assertIn(self.OLD, manifest["superseded"])
        self.assertNotIn(self.OLD, names)
        self.assertTrue(set(manifest["superseded"]).isdisjoint(names))


def _files(files):
    import http.server

    class Files(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            data = files.get(self.path)
            if data is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
    return Files


if __name__ == "__main__":
    unittest.main()

import time
import unittest

from server import Assistant, AssistantError
from test_server import FakeCatalog, response
from registry import Registry, book_fuzzy


# These tests cover the layers before the intent fallback (version B), which
# is on by default and tested on its own (test_phonetic.IntentFallbackTests).
_intent_off = None


def setUpModule():
    global _intent_off
    from unittest.mock import patch
    import workflow
    _intent_off = patch.object(workflow, "INTENT_FALLBACK", False)
    _intent_off.start()


def tearDownModule():
    _intent_off.stop()


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        def model(messages, tools):
            self.calls.append(tools)
            first = tools[0]['function']
            return response(first['name'], {key: spec['enum'][0] for key, spec in first['parameters']['properties'].items()})
        self.app = Assistant(FakeCatalog(), model)

    def turn(self, text='', session='test', **kwargs):
        return self.app.turn({'text': text, 'request_id': 'test-request', 'session_id': session, **kwargs})

    def test_general_never_calls_model_or_navigates(self):
        for text in ('你好', '???', '今天心情真好'):
            self.assertIsNone(self.turn(text)['destination'])
        self.assertEqual(self.calls, [])

    def test_registry_and_pagination(self):
        registry = Registry()
        self.assertEqual(len(registry.entries), 109)
        self.assertEqual(sum(e['enabled'] for e in registry.entries), 86)
        first = self.turn('有哪些功能')
        second = self.turn('下一頁', resolution_id=first['resolution_id'])
        self.assertEqual(first['kind'], 'capability_list')
        self.assertIsNone(first['destination'])
        self.assertNotEqual(first['choices'][0]['title'], second['choices'][0]['title'])
        self.assertEqual(self.calls, [])

    def test_joint_internal_operation_retrieval(self):
        matches = Registry().search('我要看圖書借閱排行')
        self.assertTrue(any(m['entry']['id'] == 'library.ranking' for m in matches))

    def test_ambiguous_service_waits_for_bound_confirmation(self):
        result = self.turn('案件進度')
        self.assertEqual(result['kind'], 'confirm_candidates')
        self.assertIsNone(result['destination'])
        self.assertGreater(len(result['choices']), 1)
        with self.assertRaises(AssistantError):
            self.turn(session='other', resolution_id=result['resolution_id'], choice_id='1')
        with self.assertRaises(AssistantError):
            self.turn(resolution_id=result['resolution_id'], choice_id='999')
        chosen = self.turn(resolution_id=result['resolution_id'], choice_id='1')
        self.assertIn(chosen['kind'], ('navigate', 'unsupported'))
        with self.assertRaises(AssistantError):
            self.turn(resolution_id=result['resolution_id'], choice_id='1')

    def test_one_character_book_typo_opens_the_only_match_and_says_so(self):
        for text in ('借底層羅輯', '我要借底程邏輯'):
            result = self.turn(text)
            self.assertEqual(result['destination'], {'kind': 'detail', 'book_id': 'lib-book-3'}, text)
            self.assertIn('當作《底層邏輯》', result['message'])
            self.assertIn('尚未預約', result['message'])
        self.assertEqual(self.calls, [])  # decided by the rule, not the model

    def test_other_fuzzy_books_still_require_confirmation(self):
        result = self.turn('借底邏輯')  # a character missing, not substituted
        self.assertEqual(result['kind'], 'confirm_candidates')
        self.assertIsNone(result['destination'])
        chosen = self.turn(resolution_id=result['resolution_id'], choice_id='1')
        self.assertEqual(chosen['destination'], {'kind': 'detail', 'book_id': 'lib-book-3'})
        self.assertNotEqual(self.turn('借底曾羅輯')['metrics']['route'], 'book_autocorrect')  # two characters off

    def test_multiple_books_do_not_guess_volume(self):
        result = self.turn('借神奇柑仔店')
        self.assertEqual(result['kind'], 'confirm_candidates')
        self.assertEqual(len(result['choices']), 2)
        again = self.turn('好', resolution_id=result['resolution_id'])
        self.assertIsNone(again['destination'])
        chosen = self.turn('第二本', resolution_id=result['resolution_id'])
        self.assertEqual(chosen['destination']['book_id'], 'lib-book-6')

    def test_cancel_new_subject_and_expiry_invalidate_selection(self):
        for followup in ('取消', '你好'):
            result = self.turn('有哪些功能')
            self.turn(followup, resolution_id=result['resolution_id'])
            with self.assertRaises(AssistantError):
                self.turn(resolution_id=result['resolution_id'], choice_id='1')
        result = self.turn('有哪些功能')
        self.app.workflow.pending['test']['created'] = time.monotonic() - 301
        with self.assertRaises(AssistantError):
            self.turn(resolution_id=result['resolution_id'], choice_id='1')

    def test_compound_chinese_cancels_cancel(self):
        # Rules section 3 (2026-11-13): cancel words repeated or with particles cancel too
        # (the emulator test: 算了吧 and 算了不用了 were not cancels), and say so (action).
        for text in ('取消', '請取消', '算了', '算了吧', '算了不用了', '不用了謝謝', '好，取消', '算了算了',
                     '不要了啦', '那算了', '取消。', '算了吧！'):
            listing = self.turn('有哪些功能')
            calls = len(self.calls)
            result = self.turn(text, resolution_id=listing['resolution_id'])
            self.assertEqual(result['metrics']['route'], 'cancel', text)
            self.assertEqual(result['action'], 'cancel', text)
            self.assertIsNone(result['destination'], text)
            self.assertEqual(len(self.calls), calls, text)  # no model call
            with self.assertRaises(AssistantError):
                self.turn(resolution_id=listing['resolution_id'], choice_id='1')
            self.assertTrue(self.app.workflow.known_text(text), text)

    def test_a_cancel_word_followed_by_a_request_is_the_request(self):
        for text in ('不用了，我要繳水費', '算了我要繳水費', '取消預約', '不用了解', '謝謝', '吧'):
            self.assertNotEqual(self.turn(text)['metrics']['route'], 'cancel', text)
        self.assertEqual(self.turn('不用了，我要繳水費')['destination'], {'kind': 'capability', 'id': 'fees.water'})

    def test_unavailable_never_navigates(self):
        result = self.app.workflow._navigate({'request_id': 'test', 'session_id': 'test'}, Registry().by_id['medicalAppointment'])
        self.assertEqual(result['kind'], 'unsupported')
        self.assertIsNone(result['destination'])

    def test_single_exact_unavailable_states_reason_without_model(self):
        for text, capability in (('幫我掛號', 'medicalAppointment'), ('動物園', 'zoo'), ('我要登出', 'logout'),
                                 ('不要借書，幫我掛號', 'medicalAppointment')):
            result = self.turn(text)
            self.assertEqual(result['kind'], 'unsupported')
            self.assertIsNone(result['destination'])
            self.assertIn(Registry().by_id[capability]['reason'], result['message'])
        self.assertEqual(self.calls, [])

    def test_ambiguous_set_with_unavailable_items_still_confirms(self):
        result = self.turn('案件進度')
        self.assertEqual(result['kind'], 'confirm_candidates')
        self.assertTrue(any(not choice['enabled'] for choice in result['choices']))

    def test_numeric_identifier_not_fuzzily_rewritten(self):
        self.assertEqual(book_fuzzy('9786263350718', FakeCatalog().books()), [])

    def test_negated_library_cannot_override_requested_service(self):
        result = self.turn('不要借書，幫我掛號')
        self.assertEqual(result['kind'], 'unsupported')
        self.assertIsNone(result['destination'])

    def test_multiple_intents_require_selection(self):
        for text in ('我要借書又要繳水費', '借書，然後繳水費', '借書跟繳水費', '先借書再繳水費'):
            result = self.turn(text)
            self.assertEqual(result['kind'], 'confirm_candidates', text)
            self.assertIsNone(result['destination'])

    def test_several_requests_need_no_connective_but_parents_are_one_request(self):
        registry = Registry()
        def ids(text):
            return sorted(m['entry']['id'] for m in registry.search(text))
        # Two different services, each named by its own words.
        self.assertEqual(ids('借書順便繳停車費'), ['fees.parking', 'library'])
        self.assertEqual(ids('幫我開水費跟地方稅'), ['fees.tax', 'fees.water'])
        # One request: overlapping words, a parent and its page, a word inside the other's name.
        for text, expected in (('繳費紀錄', ['fees.history']), ('水費繳費', ['fees.water']),
                               ('設定起始頁面', ['start_page']), ('圖書館排行榜', ['library.ranking']),
                               ('我要繳聯醫的醫療費', ['fees.hospital']), ('查報案進度', ['police.progress'])):
            self.assertEqual(ids(text), expected, text)
        result = self.turn('借書順便繳停車費')
        self.assertEqual(result['kind'], 'confirm_candidates')
        self.assertIsNone(result['destination'])

    def test_everyday_wording_and_spelling_variants_reach_the_feature(self):
        registry = Registry()
        for text, capability in (('我想看我的資料', 'profile'), ('我借了哪些書', 'library.records'),
                                 ('熱門的書有哪些', 'library.ranking'), ('繳費記錄', 'fees.history'),
                                 ('幫我付看病的錢', 'fees.hospital')):
            self.assertIn(capability, [m['entry']['id'] for m in registry.search(text)], text)
        for text in ('你會做什麼', '可以幫我什麼', '有哪些服務'):
            self.assertEqual(self.turn(text)['kind'], 'capability_list', text)

    def test_a_bill_named_by_its_subject_needs_a_payment_word(self):
        registry = Registry()
        def ids(text):
            return [m['entry']['id'] for m in registry.search(text)]
        self.assertEqual(ids('車子停路邊的錢要繳'), ['fees.parking'])
        self.assertEqual(ids('幫我繳醫院的帳'), ['fees.hospital'])
        self.assertEqual(ids('國宅的租金要交'), ['fees.housing'])
        for text in ('我要喝水', '醫院在哪裡', '路邊有車'):  # no payment word: not a bill
            self.assertEqual(ids(text), [], text)

    def test_a_book_title_without_a_verb_reaches_the_library(self):
        from server import retrieve
        from test_server import BOOKS
        context = retrieve('神奇柑仔店有哪幾本', BOOKS)
        self.assertEqual((context['query'], context['library'], len(context['books'])), ('神奇柑仔店', True, 2))
        self.assertEqual(retrieve('錢天堂', BOOKS)['books'][0]['id'], 'lib-book-5')
        self.assertEqual(retrieve('9786263350', BOOKS)['search_type'], 'isbn')  # digits are not a title fragment
        self.assertEqual(self.turn('神奇柑仔店有哪幾本')['kind'], 'confirm_candidates')
        self.assertEqual(retrieve('劉潤寫過的書', BOOKS)[('search_type')], 'author')

    def test_one_correction_then_fail_closed(self):
        replies = []
        def model(messages, tools):
            replies.append(messages[-1]['content'])
            if len(replies) == 1:
                return {'message': {'content': 'done'}}
            return response('select_capability', {'capability_id': 'fees.water'})
        result = Assistant(FakeCatalog(), model).turn(
            {'text': '我要繳水費', 'request_id': 'r', 'session_id': 's'})
        self.assertEqual(result['destination'], {'kind': 'capability', 'id': 'fees.water'})
        self.assertIn('Invalid output', replies[1])
        self.assertEqual(result['metrics']['model_calls'], 2)
        broken = Assistant(FakeCatalog(), lambda *_: {'message': {'content': 'done'}})
        with self.assertRaises(AssistantError):
            broken.turn({'text': '我要繳水費', 'request_id': 'r', 'session_id': 's'})

    def test_workflow_replies_carry_metrics(self):
        greeting = self.turn('你好')['metrics']
        self.assertEqual((greeting['model_calls'], greeting['model']), (0, None))
        self.assertEqual(self.turn('我要繳水費')['metrics']['model_calls'], 1)

    def test_catalog_modes_are_known_strings(self):
        self.assertTrue(all(e['mode'] in ('demo', 'local') for e in Registry().entries))


class KnownTextTests(unittest.TestCase):
    """Workflow.known_text: what the App knows, by word or sound (asr_server lets the
    Taiwanese model try unsure Chinese that matches nothing; section 13)."""

    def setUp(self):
        self.app = Assistant(FakeCatalog(), lambda *_: response('request_clarification'))
        self.known = self.app.workflow.known_text

    def test_requests_commands_books_and_sound_alikes_are_known(self):
        self.app.catalog._data = self.app.catalog.books()  # cached: titles and authors count
        for text in ('借書', '我要繳水費', '下一頁', '第二個', '弟二個', '取消', '你好', '謝謝你喔', '有哪些功能', '你會做什麼',
                     '我要解釋', '繳水廢', '借龜兔賽跑', '找一本書', '查我的借閱紀錄', '神奇柑仔店', '我想借原子習慣', '好的', '早安啊小幫手'):
            self.assertTrue(self.known(text), text)

    def test_strange_chinese_is_not_known(self):
        for text in ('溫刀揮袖促', '竟然放第一是從事進來', '狂風冰雹過兩天', '我問過律師跟法律人', '', '   '):
            self.assertFalse(self.known(text), text)

    def test_no_network_for_the_book_list(self):
        self.app.catalog._data = None  # not loaded: titles are simply not consulted
        self.assertFalse(self.known('神奇柑仔店'))
        self.assertTrue(self.known('借書'))


if __name__ == '__main__':
    unittest.main()

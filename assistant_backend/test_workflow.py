import time
import unittest

from server import Assistant, AssistantError
from test_server import FakeCatalog, response
from registry import Registry, book_fuzzy


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        def model(messages, tools):
            self.calls.append(tools)
            first = tools[0]['function']
            if first['name'] == 'select_capability':
                return response(first['name'], {'capability_id': first['parameters']['properties']['capability_id']['enum'][0]})
            return response(first['name'])
        self.app = Assistant(FakeCatalog(), model)

    def turn(self, text='', session='test', **kwargs):
        return self.app.turn({'text': text, 'request_id': 'test-request', 'session_id': session, **kwargs})

    def test_general_never_calls_model_or_navigates(self):
        for text in ('你好', '???', '今天心情真好'):
            self.assertIsNone(self.turn(text)['destination'])
        self.assertEqual(self.calls, [])

    def test_registry_and_pagination(self):
        registry = Registry()
        self.assertEqual(len(registry.entries), 70)
        self.assertEqual(sum(e['enabled'] for e in registry.entries), 41)
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

    def test_fuzzy_book_requires_confirmation(self):
        result = self.turn('借底層羅輯')
        self.assertEqual(result['kind'], 'confirm_candidates')
        self.assertIsNone(result['destination'])
        chosen = self.turn(resolution_id=result['resolution_id'], choice_id='1')
        self.assertEqual(chosen['destination'], {'kind': 'detail', 'book_id': 'lib-book-3'})

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


if __name__ == '__main__':
    unittest.main()

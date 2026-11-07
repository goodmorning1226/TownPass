import json
import pathlib
import re
import unittest

from guide import GuidePlanner
from server import Assistant
from test_server import FakeCatalog, response

ROOT = pathlib.Path(__file__).resolve().parents[1]


class GuidePlannerTests(unittest.TestCase):
    def setUp(self):
        self.planner = GuidePlanner()

    def test_expand_adds_prerequisites_in_page_order(self):
        self.assertEqual(self.planner.expand('library', ['reserve']),
                         ['open_search', 'search_keyword', 'pick_book', 'choose_branch', 'reserve'])
        self.assertEqual(self.planner.expand('library', ['hot_keyword', 'pick_book']),
                         ['open_search', 'hot_keyword', 'pick_book'])
        self.assertEqual(self.planner.expand('library', ['check_pickup']), ['open_records', 'check_pickup'])

    def test_expand_drops_unknown_ids_and_falls_back_to_default(self):
        self.assertEqual(self.planner.expand('library', ['pay_water', 'x']),
                         self.planner.expand('library', ['reserve']))

    def test_page_for_destination(self):
        self.assertEqual(self.planner.page_for({'kind': 'home'}), 'library')
        self.assertEqual(self.planner.page_for({'kind': 'capability', 'id': 'library.notices'}), 'library')
        self.assertEqual(self.planner.page_for({'kind': 'capability', 'id': 'fees.water'}), 'fees')
        self.assertEqual(self.planner.page_for({'kind': 'capability', 'id': 'fees.history'}), 'fees')
        # 地方稅 and 掃描 open the camera page: no guide.
        self.assertIsNone(self.planner.page_for({'kind': 'capability', 'id': 'fees.tax'}))
        self.assertIsNone(self.planner.page_for({'kind': 'capability', 'id': 'fees.scan'}))
        self.assertIsNone(self.planner.page_for({'kind': 'capability', 'id': 'messages'}))
        self.assertIsNone(self.planner.page_for(None))

    def test_every_page_file_is_loaded(self):
        files = sorted(p.name for p in (ROOT / 'assets/assistant').glob('guide_*.json'))
        self.assertEqual(files, sorted(f'guide_{page}.json' for page in self.planner.pages))
        self.assertIn('fees', self.planner.pages)

    def test_fees_expand_and_entry(self):
        pay = ['enter_number', 'query_bill', 'pick_bill', 'to_payment', 'choose_method', 'confirm_pay']
        self.assertEqual(self.planner.expand('fees', ['confirm_pay']), pay)
        self.assertEqual(self.planner.expand('fees', ['pick_fee', 'confirm_pay']), ['pick_fee', *pay])
        self.assertEqual(self.planner.expand('fees', ['nope']), pay)

    def test_fees_plan_uses_the_sub_page(self):
        def no_model(*args):
            raise AssertionError('not needed')
        plan = lambda text, cap: self.planner.plan(None, 'fees', text, None, None, RuntimeError, no_model,
                                                   destination={'kind': 'capability', 'id': cap})[0]['components']
        self.assertEqual(plan('我要繳水費', 'fees.water')[-1], 'confirm_pay')
        self.assertEqual(plan('我要繳水費', 'fees.water')[0], 'enter_number')
        self.assertEqual(plan('我要繳費', 'fees.other')[0], 'pick_fee')
        self.assertEqual(plan('我要繳費', 'fees.history'), ['filter_history'])
        self.assertEqual(plan('看一下', 'fees.history'), ['filter_history'])

    def test_app_has_the_same_components(self):
        """The App's pre-written steps (guides/<page>_guide.dart) use the same
        ids, titles and prerequisites as each page's shared file."""
        for page, spec in self.planner.pages.items():
            dart = (ROOT / f'lib/page/guided_assistant/model/guides/{page}_guide.dart').read_text(encoding='utf-8')
            found = re.findall(r"id: '(\w+)',\s*title: '([^']+)',[\s\S]*?requires: const \[([^\]]*)\]", dart)
            app = [(i, t, [r.strip().strip("'") for r in reqs.split(',') if r.strip()]) for i, t, reqs in found]
            shared = [(c['id'], c['title'], c['requires']) for c in spec['components']]
            self.assertEqual(app, shared, page)


class GuideWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def model(messages, tools):
            self.calls.append([t['function']['name'] for t in tools])
            first = tools[0]['function']
            if first['name'] == 'select_capability':
                return response(first['name'], {'capability_id': first['parameters']['properties']['capability_id']['enum'][0]})
            if first['name'] == 'select_goal':
                evidence = json.loads(messages[1]['content'])
                return response('select_goal', {'goal': evidence['components'][0]['id']})
            if any(t['function']['name'] == 'open_library' for t in tools):
                return response('open_library')
            return response(first['name'])
        self.app = Assistant(FakeCatalog(), model)

    def turn(self, text):
        return self.app.turn({'text': text, 'request_id': 'r', 'session_id': 's'})

    def plan(self, text, destination):
        """The guide stage alone, for a page the page stage already chose."""
        page = self.app.workflow.guides.page_for(destination)
        return self.app.workflow.guides.plan(self.app, page, text, None, None, RuntimeError,
                                             lambda *a: (_ for _ in ()).throw(RuntimeError()),
                                             destination=destination)[0]

    def test_pickup_request_gets_pickup_guide_on_the_library(self):
        self.assertEqual(self.plan('我預約的書到了沒', {'kind': 'capability', 'id': 'library'}),
                         {'page': 'library', 'components': ['open_records', 'check_pickup']})

    def test_borrow_request_gets_reserve_guide(self):
        reply = self.turn('我要借書')
        self.assertEqual(reply['kind'], 'navigate')
        self.assertEqual(reply['guide']['components'][-1], 'reserve')

    def test_notices_and_map(self):
        library = {'kind': 'capability', 'id': 'library'}
        self.assertEqual(self.plan('圖書館有什麼公告', library)['components'], ['open_notices'])
        self.assertEqual(self.plan('最近的分館在哪', library)['components'], ['open_map'])

    def test_water_fee_opens_the_bill_page_with_the_pay_guide(self):
        reply = self.turn('我要繳水費')
        self.assertEqual(reply['destination'], {'kind': 'capability', 'id': 'fees.water'})
        self.assertEqual(reply['guide']['page'], 'fees')
        self.assertEqual(reply['guide']['components'][0], 'enter_number')
        self.assertEqual(reply['guide']['components'][-1], 'confirm_pay')

    def test_fee_history_gets_the_filter_guide(self):
        reply = self.turn('我要看繳費紀錄')
        self.assertEqual(reply['guide'], {'page': 'fees', 'components': ['filter_history']})

    def test_other_services_get_no_guide(self):
        reply = self.turn('你好')
        self.assertNotIn('guide', reply)


if __name__ == '__main__':
    unittest.main()

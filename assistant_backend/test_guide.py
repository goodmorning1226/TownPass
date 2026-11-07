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
            # Lettered choices: the offered tool calls are the options in the last message.
            options = json.loads(messages[-1]['content']).get('options', [])
            if isinstance(options, dict):  # library: {"A": "tool(args): description"}
                options = [{'choice': letter, 'tool': line.split(':')[0].split('(')[0]}
                           for letter, line in options.items()]
            self.calls.append(list(dict.fromkeys(o['tool'] for o in options)))
            names = [o['tool'] for o in options]
            if 'select_goal' in names:
                goal = json.loads(messages[1]['content'])['components'][0]['id']
                chosen = next(o for o in options if o['tool'] == 'select_goal' and o['arguments']['goal'] == goal)
            elif 'open_library' in names:
                chosen = next(o for o in options if o['tool'] == 'open_library')
            else:
                chosen = options[0]  # first tool, first candidate
            return response('choose', {'choice': chosen['choice']})
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


class GuideChoiceTests(unittest.TestCase):
    """The guide stage with lettered options (decision.DECISION_FORMAT "choice")."""

    def setUp(self):
        self.offered = []
        self.pick = None

        def model(messages, tools):
            options = json.loads(messages[-1]['content']).get('options', [])
            self.offered.append(options)
            chosen = next((o for o in options if self.pick and self.pick(o)), options[0])
            return response('choose', {'choice': chosen['choice']})
        self.app = Assistant(FakeCatalog(), model)

    def plan(self, page, text, destination=None):
        from decision import decide
        from server import AssistantError, tool, validate_call
        return self.app.workflow.guides.plan(self.app, page, text, tool, validate_call, AssistantError, decide,
                                             destination=destination)

    def test_two_requests_offer_unordered_pairs_within_26_options(self):
        self.pick = lambda o: o['tool'] == 'select_two_goals'
        plan, route = self.plan('library', '我想先弄這個然後再弄那個')  # a connective, no keyword
        self.assertEqual(route, 'guide_model')
        options = self.offered[-1]
        self.assertLessEqual(len(options), 26)
        pairs = [o['arguments']['pair'].split('+') for o in options if o['tool'] == 'select_two_goals']
        self.assertEqual(len(pairs), 10)  # C(5, 2)
        self.assertTrue(all(a != b for a, b in pairs))
        self.assertEqual(len({frozenset(p) for p in pairs}), 10)  # no (a, b) and (b, a)
        singles = [o for o in options if o['tool'] == 'select_goal']
        self.assertEqual(len(singles), len(self.app.workflow.guides.pages['library']['components']))
        self.assertTrue(set(pairs[0]) <= set(plan['components']))

    def test_one_request_offers_single_goals_only(self):
        self.plan('library', '這個要怎麼用')  # a question, no keyword, no connective
        self.assertEqual({o['tool'] for o in self.offered[-1]}, {'select_goal'})

    def test_every_page_fits_in_the_lettered_options(self):
        planner = self.app.workflow.guides
        asked = 0
        for page, spec in planner.pages.items():
            for cap in [None, *spec.get('capability_goals', {})]:
                destination = {'kind': 'capability', 'id': cap} if cap else None
                self.offered.clear()
                self.plan(page, '先弄這個然後再弄那個', destination)  # choice_options raises past 26
                asked += len(self.offered)
                for options in self.offered:
                    self.assertLessEqual(len(options), 26, (page, cap))
        self.assertGreater(asked, 0)

    def test_choice_options_refuse_more_than_26(self):
        from decision import choice_options
        from server import tool
        enum = {'type': 'string', 'enum': [f'g{i}' for i in range(26)]}
        self.assertEqual(len(choice_options([tool('pick', 'x', {'goal': enum}, ['goal'])])), 26)
        with self.assertRaises(ValueError):
            choice_options([tool('pick', 'x', {'goal': enum}, ['goal']), tool('request_clarification', 'y')])

    def test_other_languages_get_the_page_task_without_a_model_call(self):
        reply = self.app.turn({'text': 'I want to pay my water bill', 'request_id': 'r', 'session_id': 's',
                               'language': 'en'})
        self.assertEqual(reply['kind'], 'navigate')
        self.assertEqual(reply['destination'], {'kind': 'capability', 'id': 'fees.water'})
        planner = self.app.workflow.guides
        self.assertEqual(reply['guide'], planner.default_plan('fees', reply['destination']))
        self.assertEqual(reply['guide']['components'][-1], 'confirm_pay')
        self.assertEqual(self.app.usage.guide_route, 'guide_default_language')
        guide_calls = [o for o in self.offered if any(x['tool'] in ('select_goal', 'select_two_goals') for x in o)]
        self.assertEqual(guide_calls, [])


if __name__ == '__main__':
    unittest.main()

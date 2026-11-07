import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 訂閱 (subscription): recordings of a user who does only what the cards
/// say. Scenarios: tool/guide_audit/scenarios/sub_*.json.
void main() {
  const ok = {
    'sub_subscribe': '預設：打開停車費通知、訂閱',
    'sub_pick_topic': '打開防汛資訊',
    'sub_items_read': '訂閱的訊息：打開一則',
    'sub_items_settings': '訂閱的訊息：按設定',
  };
  for (final e in ok.entries) {
    test('${e.value} (${e.key})', () {
      final r = replayFixture(e.key);
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  }

  test('unsubscribe with 您已訂閱 0 項 says there is nothing to cancel', () {
    final r = replayFixture('sub_unsubscribe_none');
    printOnFailure(r.report);
    expect(r.problems, isEmpty);
    expect(r.trace.last, contains('不用取消'));
  });

  group('SUB-1: subscribe + unsubscribe plan ends done', () {
    test('page facts: the topic was subscribed, then unsubscribed', () {
      final fx = loadFixture('sub_subscribe_then_unsubscribe');
      final steps = (fx['steps'] as List).cast<Map<String, dynamic>>();
      Map flags(int i) => (steps[i]['after'] as Map)['flags'] as Map;
      expect(flags(2)['onTitles'], '健康報報');
      expect(flags(4)['count'], 0);
    });

    test('after 取消訂閱 the guide is done', () {
      final r = replayFixture('sub_subscribe_then_unsubscribe');
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
      expect(r.trace.last, isNot(contains('[pick_topic]')));
    });
  });
}

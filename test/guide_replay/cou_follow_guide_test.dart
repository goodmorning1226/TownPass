import 'package:flutter_test/flutter_test.dart';

import 'replay.dart';

/// 優惠 / 票夾 (coupon_wallet): recordings of a user who does only what the
/// cards say. Scenarios: tool/guide_audit/scenarios/cou_*.json.
void main() {
  const ok = {
    'cou_list_default': 'coupon.list 預設：‹、優惠券、選一張',
    'cou_add_wallet': '加入票夾、存入票夾',
    'cou_use_coupon': '立即使用、使用、確定',
    'cou_add_then_use': '加入票夾後按使用優惠，從票夾兌換',
    'cou_wallet_coupons': '票夾的優惠券',
    'cou_wallet_used': '票夾的已兌換',
    'cou_wallet_pick': '打開票夾的優惠券',
    'cou_wallet_use': '從票夾兌換',
    'cou_wallet_ticket': '入場券 QR code',
  };
  for (final e in ok.entries) {
    test('${e.value} (${e.key})', () {
      final r = replayFixture(e.key);
      printOnFailure(r.report);
      expect(r.problems, isEmpty);
      expect(r.done, isTrue);
    });
  }

  group('COU-1: pick_coupon always says 「下面還有」', () {
    test('page facts: all coupon cards are on screen', () {
      final fx = loadFixture('cou_list_default');
      final s = (fx['steps'] as List)[2] as Map<String, dynamic>;
      final flags = (s['after'] as Map<String, dynamic>)['flags'] as Map;
      expect(flags['cards'], 3);
      expect(flags['cardsBelow'], isFalse);
    });

    test(
      'the card only mentions more coupons below when there are some',
      () {
        final r = replayFixture('cou_list_default');
        printOnFailure(r.report);
        expect(r.trace[2], isNot(contains('下面還有')));
      },
      skip:
          'COU-1: pick_coupon card text ignores the cardsBelow flag and always '
          'says 「下面還有，可以往下滑看看」.',
    );
  });
}

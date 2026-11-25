import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guide_target.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guided_assistant_controller.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_i18n.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guides/guide_registry.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/widget/guide_card_layout.dart';

/// The penguin card keeps off the ring (portal_assistant/docs/AI_CURRENT_RULES.md section 5,
/// 2026-11-16): beside it when it fits, else one line that opens on a tap
/// and shows the step's short point.

const _screen = Size(400, 800);

/// A free area like a phone: status bar 24, title bar to 84, the penguin
/// button from 688.
GuideCardPlacement _place({
  required double full,
  double preferred = 86,
  Rect? ring,
  double bottom = 688,
  GuideCardPlacement? current,
}) => GuideCardLayout.place(
  areaTop: 32,
  comfortTop: 84,
  areaBottom: bottom,
  fullHeight: full,
  preferredTop: preferred,
  target: ring,
  current: current,
);

bool _clear(GuideCardPlacement p, double h, Rect ring) =>
    p.top + h <= ring.top - GuideCardLayout.gap + 0.5 ||
    p.top >= ring.bottom + GuideCardLayout.gap - 0.5;

Rect _rows(double top, double bottom) => Rect.fromLTRB(16, top, 384, bottom);

/// A screen with a lit target at [ring] and the real card placer, the card
/// being [text] (its height measured as the App does).
Widget _page({
  required Rect ring,
  required String text,
  Rect? next,
  double preferred = 86,
  double textScale = 1,
  EdgeInsets keyboard = EdgeInsets.zero,
}) {
  Widget body(bool opened, VoidCallback collapse) => Container(
    padding: const EdgeInsets.all(12),
    color: const Color(0xFFFFF4D6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Step 3 / 5 · Pick one')),
            if (opened)
              IconButton(
                key: const Key('collapse'),
                onPressed: collapse,
                icon: const Icon(Icons.expand_less),
              ),
          ],
        ),
        Text(text, style: const TextStyle(fontSize: 17, height: 25 / 17)),
      ],
    ),
  );
  return MediaQuery(
    data: MediaQueryData(
      size: _screen,
      padding: const EdgeInsets.only(top: 24),
      viewInsets: keyboard,
      textScaler: TextScaler.linear(textScale),
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        child: Builder(
          builder: (context) {
            final area = GuideCardLayout.areaOf(MediaQuery.of(context));
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: ring,
                  child: const GuideTarget(
                    id: 'ring',
                    child: ColoredBox(color: Color(0xFFDDDDDD)),
                  ),
                ),
                if (next != null)
                  Positioned.fromRect(
                    rect: next,
                    child: const GuideTarget(
                      id: 'next',
                      child: ColoredBox(color: Color(0xFFBBBBBB)),
                    ),
                  ),
                Positioned.fill(
                  child: GuideCardPlacer(
                    target: 'ring',
                    nextTarget: next == null ? null : 'next',
                    preferredTop: preferred,
                    areaTop: area.areaTop,
                    comfortTop: area.comfortTop,
                    areaBottom: area.areaBottom,
                    stepKey: 'step:3',
                    measure: (opened) => body(opened, () {}),
                    full: (opened, collapse) => KeyedSubtree(
                      key: const Key('full-card'),
                      child: body(opened, collapse),
                    ),
                    compact: (open) => GestureDetector(
                      key: const Key('one-line'),
                      onTap: open,
                      child: SizedBox(
                        height: GuideCardLayout.compactHeight,
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    wrap: (card) => card,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  // Measure (one frame), then the move animation.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
}

Rect _card(WidgetTester tester) {
  final full = find.byKey(const Key('full-card'));
  return tester.getRect(
    full.evaluate().isNotEmpty ? full : find.byKey(const Key('one-line')),
  );
}

bool _overlaps(Rect card, Rect ring) =>
    card.bottom > ring.top + 0.5 && card.top < ring.bottom - 0.5;

const _short = 'Found them! Tap the title of the book you want.';
const _long =
    'No books were found this time. Type another title in the box at the '
    'top, for example “Magical Cito Store”, and tap the magnifying glass. '
    'To see the “Popular keyword” again, delete the words in the box and '
    'tap the magnifying glass.';

void main() {
  setUp(() => GuideTargets.setWebRects(const {}));

  group('short points for the one-line card', () {
    setUpAll(GuideI18n.load);

    test('every step of every guide has one, in all six languages', () {
      final missing = <String>[];
      for (final page in guidePages) {
        for (final c in page.components) {
          expect(
            c.briefs.length,
            lessThanOrEqualTo(c.steps.length),
            reason: '${page.id}.${c.id}: one per step',
          );
          for (var j = 0; j < c.steps.length; j++) {
            final where = '${page.id}.${c.id}#$j';
            final brief = j < c.briefs.length ? c.briefs[j].trim() : '';
            if (brief.isEmpty) {
              missing.add('$where: none');
              continue;
            }
            for (final code in const ['en', 'ja', 'vi', 'id', 'tl']) {
              if (!GuideI18n.has(brief, code)) missing.add('$where: $code');
            }
          }
        }
      }
      expect(missing, isEmpty);
    });

    test('the built guide carries them on its steps', () {
      for (final page in guidePages) {
        final guide = page.build(
          page.plan([for (final c in page.components) c.id]),
        );
        for (final step in guide.steps) {
          expect(step.brief, isNotNull, reason: guide.id);
        }
      }
    });

    test('no short point: the card\'s first sentence', () {
      expect(GuideCard.firstSentence('打好了！按下面的「查詢」，看看要繳多少錢。'), '打好了！');
      expect(
        GuideCard.firstSentence('Done! Tap “Search” below. Then pay.'),
        'Done!',
      );
      expect(GuideCard.firstSentence('No full stop'), 'No full stop');
      expect(GuideCard.firstSentence('v1.2 is out. Ok'), 'v1.2 is out.');
    });
  });

  group('GuideCardLayout.place', () {
    test('the preferred place stays when it is clear of the ring', () {
      final p = _place(full: 200, ring: _rows(500, 560));
      expect(p, const GuideCardPlacement(86));
    });

    test('ring in the upper half: the card goes below it', () {
      final ring = _rows(96, 150);
      final p = _place(full: 200, ring: ring);
      expect(p.compact, isFalse);
      expect(p.top, 150 + GuideCardLayout.gap);
      expect(_clear(p, 200, ring), isTrue);
    });

    test('ring in the lower half: the side nearest the preferred place', () {
      final ring = _rows(480, 540);
      final p = _place(full: 200, preferred: 420, ring: ring);
      expect(p.compact, isFalse);
      expect(p.top, 480 - GuideCardLayout.gap - 200, reason: 'above');
      expect(_clear(p, 200, ring), isTrue);
    });

    test('a ring as big as the screen: one line where it covers least', () {
      final ring = _rows(140, 900);
      final p = _place(full: 200, ring: ring);
      expect(p.compact, isTrue);
      expect(
        _clear(p, GuideCardLayout.compactHeight, ring),
        isTrue,
        reason: 'one line above the list (over the title bar if needed)',
      );
      // Nowhere clear: at the top or bottom edge, still one line.
      final all = _place(full: 200, ring: _rows(0, 900));
      expect(all.compact, isTrue);
      expect(all.top, anyOf(84, 688 - GuideCardLayout.compactHeight));
    });

    test('keyboard up: the card moves above it, or shrinks to one line', () {
      final ring = _rows(120, 170);
      // Keyboard from 420: 200 high card fits below the field.
      final up = _place(full: 200, ring: ring, bottom: 412);
      expect(up, const GuideCardPlacement(170 + GuideCardLayout.gap));
      // A taller card does not: one line next to the field.
      final tall = _place(full: 300, ring: ring, bottom: 412);
      expect(tall.compact, isTrue);
      expect(_clear(tall, GuideCardLayout.compactHeight, ring), isTrue);
      expect(tall.top + GuideCardLayout.compactHeight, lessThanOrEqualTo(412));
    });

    test('a tall card (English, large text) uses its real height', () {
      final ring = _rows(300, 360);
      final p = _place(full: 300, ring: ring);
      expect(p, const GuideCardPlacement(360 + GuideCardLayout.gap));
      final taller = _place(full: 340, ring: ring);
      expect(taller.compact, isTrue, reason: 'neither side has 340');
      expect(_clear(taller, GuideCardLayout.compactHeight, ring), isTrue);
    });

    test('the other usable parts are kept clear when there is room', () {
      // Library search: the ring is the search row, 熱門關鍵字 right below.
      final row = _rows(96, 150), hot = _rows(160, 400);
      final p = GuideCardLayout.place(
        areaTop: 32,
        comfortTop: 84,
        areaBottom: 688,
        fullHeight: 200,
        preferredTop: 135,
        target: row,
        others: [hot],
      );
      expect(p, const GuideCardPlacement(400 + GuideCardLayout.gap));
      // No room beside both: only the ring is kept clear.
      final big = GuideCardLayout.place(
        areaTop: 32,
        comfortTop: 84,
        areaBottom: 688,
        fullHeight: 200,
        preferredTop: 135,
        target: row,
        others: [_rows(160, 680)],
      );
      expect(big, const GuideCardPlacement(150 + GuideCardLayout.gap));
    });

    test('the next step\'s target is kept clear when there is room', () {
      // 繳費, keyboard up: the 水號 box is lit, 查詢 comes next.
      final field = _rows(282, 337), query = _rows(507, 554);
      GuideCardPlacement at({Rect? next}) => GuideCardLayout.place(
        areaTop: 44,
        comfortTop: 84,
        areaBottom: 577,
        fullHeight: 176,
        preferredTop: 352,
        target: field,
        next: [?next],
      );
      expect(at(), const GuideCardPlacement(352), reason: 'covers 查詢');
      final p = at(next: query);
      expect(p, const GuideCardPlacement(282 - GuideCardLayout.gap - 176));
      expect(_clear(p, 176, query), isTrue);
      expect(_clear(p, 176, field), isTrue);
    });

    test('no room for the next target: only the ring is kept clear', () {
      final ring = _rows(120, 170), next = _rows(360, 420);
      final p = GuideCardLayout.place(
        areaTop: 44,
        comfortTop: 84,
        areaBottom: 577,
        fullHeight: 176,
        preferredTop: 200,
        target: ring,
        next: [next],
      );
      expect(p, const GuideCardPlacement(200));
      expect(p.compact, isFalse, reason: 'not shrunk for the next target');
      expect(_clear(p, 176, ring), isTrue);
    });

    test('a place still clear stays put (no jumping while scrolling)', () {
      const now = GuideCardPlacement(400);
      final kept = _place(full: 200, ring: _rows(100, 160), current: now);
      expect(kept, now);
      // The ring scrolled under the card: it moves.
      final moved = _place(full: 200, ring: _rows(380, 440), current: now);
      expect(moved, isNot(now));
    });

    test('no ring: the preferred place, kept inside the free area', () {
      expect(_place(full: 200), const GuideCardPlacement(86));
      expect(
        _place(full: 200, preferred: 600),
        const GuideCardPlacement(688 - 200),
      );
      // A dialog step may sit over the title bar on purpose.
      expect(_place(full: 200, preferred: 44), const GuideCardPlacement(44));
    });

    test('the free area follows the keyboard and the safe area', () {
      const media = MediaQueryData(
        size: _screen,
        padding: EdgeInsets.only(top: 24, bottom: 20),
      );
      final closed = GuideCardLayout.areaOf(media);
      expect(closed.areaTop, 32);
      expect(closed.comfortTop, 84);
      expect(closed.areaBottom, 800 - 20 - 88);
      final open = GuideCardLayout.areaOf(
        media.copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
      );
      expect(open.areaBottom, 800 - 300 - 8);
    });
  });

  group('GuideCardPlacer', () {
    testWidgets('ring in the upper half: the card is below it', (tester) async {
      const ring = Rect.fromLTRB(16, 90, 384, 160);
      await tester.pumpWidget(_page(ring: ring, text: _short));
      await _settle(tester);
      final card = _card(tester);
      expect(_overlaps(card, ring), isFalse);
      expect(card.top, greaterThan(ring.bottom));
    });

    testWidgets('ring in the lower half: the card stays above it', (
      tester,
    ) async {
      const ring = Rect.fromLTRB(16, 520, 384, 600);
      await tester.pumpWidget(_page(ring: ring, text: _short, preferred: 470));
      await _settle(tester);
      final card = _card(tester);
      expect(_overlaps(card, ring), isFalse);
      expect(card.bottom, lessThan(ring.top));
    });

    testWidgets('a ring filling the screen: one line; a tap opens the card', (
      tester,
    ) async {
      const ring = Rect.fromLTRB(16, 150, 384, 780);
      await tester.pumpWidget(_page(ring: ring, text: _long, preferred: 470));
      await _settle(tester);
      expect(find.byKey(const Key('one-line')), findsOneWidget);
      expect(find.byKey(const Key('full-card')), findsNothing);
      expect(_overlaps(_card(tester), ring), isFalse);
      await tester.tap(find.byKey(const Key('one-line')));
      await _settle(tester);
      expect(find.byKey(const Key('full-card')), findsOneWidget);
      // Opened by hand: it may cover the ring, and can be shrunk again.
      await tester.tap(find.byKey(const Key('collapse')));
      await _settle(tester);
      expect(find.byKey(const Key('one-line')), findsOneWidget);
    });

    testWidgets('the keyboard opens: the card moves above it', (tester) async {
      const ring = Rect.fromLTRB(16, 100, 384, 150);
      await tester.pumpWidget(_page(ring: ring, text: _short, preferred: 300));
      await _settle(tester);
      expect(_card(tester).top, 300);
      await tester.pumpWidget(
        _page(
          ring: ring,
          text: _short,
          preferred: 300,
          keyboard: const EdgeInsets.only(bottom: 420),
        ),
      );
      await _settle(tester);
      final card = _card(tester);
      expect(card.bottom, lessThanOrEqualTo(800 - 420));
      expect(_overlaps(card, ring), isFalse);
    });

    testWidgets('large text: the measured (taller) card still keeps clear', (
      tester,
    ) async {
      const ring = Rect.fromLTRB(16, 330, 384, 390);
      await tester.pumpWidget(_page(ring: ring, text: _short));
      await _settle(tester);
      final normal = _card(tester);
      await tester.pumpWidget(_page(ring: ring, text: _long, textScale: 2));
      await _settle(tester);
      final big = _card(tester);
      expect(_overlaps(normal, ring), isFalse);
      expect(_overlaps(big, ring), isFalse);
      // The long card at double size does not fit beside the ring.
      expect(find.byKey(const Key('one-line')), findsOneWidget);
    });

    testWidgets('a ring that moves a little leaves the card where it is', (
      tester,
    ) async {
      const ring = Rect.fromLTRB(16, 500, 384, 560);
      await tester.pumpWidget(_page(ring: ring, text: _short));
      await _settle(tester);
      final before = _card(tester);
      // The page scrolled: the web ring moved up by 40.
      GuideTargets.setWebRects({'ring': ring.shift(const Offset(0, -40))});
      await tester.pump(GuideCardPlacer.checkEvery);
      await _settle(tester);
      expect(_card(tester), before);
    });

    testWidgets('the next step\'s target is kept clear too', (tester) async {
      const ring = Rect.fromLTRB(16, 300, 384, 350);
      const next = Rect.fromLTRB(16, 470, 384, 520);
      await tester.pumpWidget(_page(ring: ring, text: _short, preferred: 400));
      await _settle(tester);
      expect(_overlaps(_card(tester), next), isTrue, reason: 'not told');
      await tester.pumpWidget(
        _page(ring: ring, next: next, text: _short, preferred: 400),
      );
      await tester.pump(GuideCardPlacer.checkEvery);
      await _settle(tester);
      final card = _card(tester);
      expect(_overlaps(card, next), isFalse);
      expect(_overlaps(card, ring), isFalse);
    });

    testWidgets('no room beside the next target: only the ring is kept clear', (
      tester,
    ) async {
      const ring = Rect.fromLTRB(16, 100, 384, 150);
      const next = Rect.fromLTRB(16, 220, 384, 280);
      await tester.pumpWidget(
        _page(
          ring: ring,
          next: next,
          text: _short,
          preferred: 200,
          keyboard: const EdgeInsets.only(bottom: 420),
        ),
      );
      await _settle(tester);
      final card = _card(tester);
      expect(find.byKey(const Key('full-card')), findsOneWidget);
      expect(_overlaps(card, ring), isFalse);
      expect(_overlaps(card, next), isTrue, reason: 'no room for both');
    });
  });
}

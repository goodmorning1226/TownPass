import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/assistant/widget/taiwanese_prompt.dart';

void main() {
  late List<String> chosen;

  Future<void> open(WidgetTester tester, {String current = 'zh'}) async {
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    TaiwanesePrompt.maybeAsk(currentLanguage: current, choose: chosen.add);
    await tester.pumpAndSettle();
  }

  setUp(() {
    chosen = [];
    TaiwanesePrompt.enabled = true;
    TaiwanesePrompt.reset();
  });

  tearDown(() => TaiwanesePrompt.enabled = false);

  testWidgets('"是" picks 台語 and the question is not asked again', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await open(tester);
    expect(find.text('您是否為台語用戶？'), findsOneWidget);
    await tester.tap(find.text('是，我說台語'));
    await tester.pumpAndSettle();
    expect(chosen, ['nan']);
    expect(
      (await SharedPreferences.getInstance()).getBool(TaiwanesePrompt.key),
      isTrue,
    );
    await open(tester);
    expect(find.text('您是否為台語用戶？'), findsNothing);
  });

  testWidgets('"不是" keeps the choice and is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await open(tester);
    await tester.tap(find.text('不是'));
    await tester.pumpAndSettle();
    expect(chosen, isEmpty);
    await open(tester);
    expect(find.text('您是否為台語用戶？'), findsNothing);
  });

  testWidgets('closing without an answer asks again next time', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await open(tester);
    Get.back();
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getBool(TaiwanesePrompt.key),
      isNull,
    );
    await open(tester);
    expect(find.text('您是否為台語用戶？'), findsOneWidget);
  });

  testWidgets('not asked when 台語 is already chosen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await open(tester, current: 'nan');
    expect(find.text('您是否為台語用戶？'), findsNothing);
  });
}

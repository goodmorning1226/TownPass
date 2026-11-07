import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/util/tp_web_view.dart';

// No JS engine is available in unit tests, so these check the script's
// contract for the guided assistant's probes as text.
void main() {
  final script = translationScriptForTest;

  test('translation script exposes the original-text lookups', () {
    expect(script, contains('window.__townpassOriginal = function'));
    expect(script, contains('window.__townpassOriginalPlaceholder = function'));
  });

  test(
    'translation script keeps the original placeholder in a data attribute',
    () {
      final keep = script.indexOf("setAttribute('data-tp-placeholder'");
      final replace = script.indexOf("setAttribute('placeholder', translated)");
      expect(keep, greaterThan(-1));
      expect(replace, greaterThan(keep));
    },
  );

  test('translation script remembers original text before writing', () {
    final remember = script.indexOf('original.set(item.node, item.text)');
    final write = script.indexOf('item.node.nodeValue = value');
    expect(remember, greaterThan(-1));
    expect(write, greaterThan(remember));
  });

  test('translation script keeps its batching and observer', () {
    expect(script, contains('all.slice(start, start + 20)'));
    expect(script, contains('new MutationObserver(schedule)'));
  });
}

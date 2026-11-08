import 'package:flutter_test/flutter_test.dart';
import 'package:town_pass/util/tp_web_view.dart';

// No JS engine is available in unit tests, so these check the script's
// contract for the guided assistant's probes as text.
void main() {
  final script = translationScriptForTest;

  test('translation script exposes the original-text lookups', () {
    expect(script, contains('window.__townpassOriginal = function'));
    expect(script, contains('window.__townpassOriginalPlaceholder = function'));
    expect(script, contains('window.__townpassOriginalAttribute = '));
  });

  test(
    'translation script keeps the original placeholder in a data attribute',
    () {
      // Written generically for every translated attribute, so the placeholder
      // probe still finds data-tp-placeholder.
      final keep = script.indexOf("setAttribute('data-tp-' + item.attribute");
      final replace = script.indexOf(
        'item.el.setAttribute(item.attribute, translated)',
      );
      expect(keep, greaterThan(-1));
      expect(replace, greaterThan(keep));
      expect(script, contains("originalAttribute(el, 'placeholder')"));
      expect(script, contains("el.hasAttribute('data-tp-' + name)"));
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
    // Re-rendered nodes and attributes are picked up after a short debounce.
    expect(
      script,
      contains('childList: true, subtree: true, characterData: true'),
    );
    expect(script, contains('attributeFilter: attributes'));
    expect(script, contains('setTimeout(scan, 300)'));
  });

  test('translation script translates visible attributes, not form data', () {
    expect(
      script,
      contains("['placeholder', 'title', 'aria-label', 'alt', 'value']"),
    );
    expect(script, contains('input[type=button][value]:not([name])'));
    expect(script, contains('input[type=submit][value]:not([name])'));
    expect(script, contains('input[type=reset][value]:not([name])'));
    // A text input's value, or a named button's, is never translated.
    expect(
      script,
      contains(
        "if (el.tagName !== 'INPUT' || el.hasAttribute('name')) return false;",
      ),
    );
    expect(
      script,
      contains("type === 'button' || type === 'submit' || type === 'reset'"),
    );
  });

  test(
    'translation script skips translate="no", scripts and editable text',
    () {
      expect(script, contains('[translate="no"], .notranslate'));
      expect(
        script,
        contains('SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 1, CODE: 1'),
      );
      expect(script, contains('parent.isContentEditable'));
      // The exclusion applies to text nodes and to attributes.
      expect(script, contains('excluded(parent)'));
      expect(script, contains('if (excluded(el)) continue;'));
    },
  );

  test('translation script sends short Chinese strings, skips non-Chinese', () {
    // No minimum length: 「查詢」「送出」 are sent; the only filter is a
    // Chinese character, so numbers and dates in digits are left alone.
    expect(script, contains('chinese.test(value)'));
    expect(script, isNot(contains('.trim().length')));
    expect(script, isNot(contains('text.length')));
    expect(script, isNot(contains('value.length')));
  });

  test('translation script rescans a page larger than one pass', () {
    expect(script, contains('var limit = 400;'));
    expect(script, contains('items.slice(0, limit)'));
    expect(script, contains('if (all.length >= limit) schedule();'));
  });
}

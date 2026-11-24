import 'package:flutter_test/flutter_test.dart';
import 'package:townpass_portal_assistant/service/assistant_page_tracker.dart';
import 'package:townpass_portal_assistant/host/assistant_web_view.dart';

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
      final keep = script.indexOf("el.setAttribute('data-tp-' + name, text)");
      final replace = script.indexOf('el.setAttribute(name, translated)');
      expect(keep, greaterThan(-1));
      expect(replace, greaterThan(keep));
      expect(script, contains("originalAttribute(el, 'placeholder')"));
      expect(script, contains("el.hasAttribute('data-tp-' + name)"));
    },
  );

  test('translation script remembers original text before writing', () {
    final remember = script.indexOf('original.set(node, text)');
    final write = script.indexOf('node.nodeValue = value');
    expect(remember, greaterThan(-1));
    expect(write, greaterThan(remember));
  });

  test('translation script writes cached texts before the page paints', () {
    // portal_assistant/docs/AI_CURRENT_RULES.md section 4 (2026-11-13): injected at document
    // start, it observes the whole document (there is no body yet) and
    // writes dictionary hits inside the observer callback.
    expect(
      script,
      contains('new MutationObserver(observed).observe(document,'),
    );
    expect(
      script,
      contains('childList: true, subtree: true, characterData: true'),
    );
    expect(script, contains('attributeFilter: attributes'));
    final lookup = script.indexOf('var translated = dictionary[key];');
    final write = script.indexOf(
      'if (translated) { writeNode(node, value, translated); return; }',
    );
    expect(lookup, greaterThan(-1));
    expect(write, greaterThan(lookup));
    // 2026-11-15: with the texts that are never translated (language names).
    expect(script, contains('add(config.dictionary, config.keep);'));
  });

  test('translation script sends new texts at once, batches in parallel', () {
    // No 300 ms debounce for the first pass or route changes; rescans are
    // coalesced in a microtask.
    expect(script, isNot(contains('setTimeout(scan')));
    expect(script, contains('Promise.resolve().then(function () {'));
    expect(script, contains('var batch = 20;'));
    expect(
      script,
      contains('outbox.splice(0, Math.min(batch, limit - inFlight))'),
    );
    // Every batch is sent before any answer is awaited.
    expect(script, contains('while (outbox.length && inFlight < limit)'));
    expect(script, contains("bridge.callHandler('townpassTranslate', texts)"));
  });

  test(
    'translation script hides only waiting elements, for a limited time',
    () {
      // A transparent text colour on the waiting element; never visibility,
      // opacity or the whole body (the guide probes' `shown` stays true).
      expect(script, contains('[data-tp-pending],[data-tp-pending-sentence],[data-tp-pending-sentence] *{color:transparent!important'));
      expect(script, isNot(contains('visibility')));
      expect(script, isNot(contains('opacity')));
      expect(script, isNot(contains('document.body.style')));
      expect(script, contains('until: Date.now() + coverMs'));
      expect(script, contains('if (c.until <= now) uncover(waiting[i]);'));
      expect(AssistantWebSession.translationCoverMs, 1500);
    },
  );

  test('translation script runs only on the service host main frame', () {
    expect(
      script,
      contains(
        "if (location.protocol !== 'https:' || location.host !== config.host) return;",
      ),
    );
    expect(script, contains('if (window.top !== window) return;'));
    // A second injection (onLoadStop fallback) adds and rescans only.
    expect(
      script,
      contains(
        'window.__townpassTranslate.add(config.dictionary, config.keep);',
      ),
    );
  });

  test('translation source passes the host, language and dictionary', () {
    final source = AssistantWebSession.translationSource('en', {'水費': 'Water bill'});
    expect(source, startsWith(';'));
    expect(source, contains('"host":"${AssistantPageTracker.serviceHost}"'));
    expect(source, contains('"language":"en"'));
    expect(source, contains('"dictionary":{"水費":"Water bill"}'));
    expect(source, contains('"keep":[]'));
    expect(source, contains('"coverMs":1500'));
    expect(source, endsWith('});'));
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
      expect(script, contains('if (excluded(el)) return;'));
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

  test('translation script translates whole sentences', () {
    // portal_assistant/docs/AI_CURRENT_RULES.md section 4 (服務頁翻譯的品質): a block of only
    // text and non-interactive inline elements is one sentence per BR part.
    expect(
      script,
      contains(
        "var inlineTags = { SPAN: 1, B: 1, STRONG: 1, EM: 1, I: 1, U: 1, S: 1, SMALL: 1, MARK: 1,",
      ),
    );
    expect(script, contains('P: 1, LI: 1, TD: 1, TH: 1, LABEL: 1'));
    expect(script, isNot(contains('BUTTON: 1')));
    // Interactive or excluded inline elements, and flex/grid rows, are not.
    expect(
      script,
      contains("c.hasAttribute('tabindex') || c.hasAttribute('role')"),
    );
    expect(
      script,
      contains(
        "if (/flex|grid|table-row/.test(getComputedStyle(el).display)) return false;",
      ),
    );
    expect(script, contains("if (n.tagName === 'BR') out.push([]);"));
    // Two Chinese parts at least, so 水號<span>*</span> keeps its marker.
    expect(script, contains('if (parts < 2) return;'));
    // Written into the first text node, others emptied; the head keeps the
    // whole Chinese sentence for __townpassOriginal.
    expect(
      script,
      contains("var value = n === head ? lead + translated + tail : '';"),
    );
    expect(script, contains("original.set(n, n === head ? text : '');"));
    // A sentence the page changed is restored and translated again.
    expect(script, contains('function restore(rec)'));
    expect(script, contains('[data-tp-pending-sentence] *{color:transparent'));
  });

  test('translation script sends a page larger than one pass in turns', () {
    // At most 400 texts wait for the App; the rest go when answers return.
    expect(script, contains('var limit = 400;'));
    expect(script, contains('inFlight -= texts.length;'));
    final answer = script.indexOf('answer(texts, out);');
    final more = script.indexOf('flush();', answer);
    expect(answer, greaterThan(-1));
    expect(more, greaterThan(answer));
  });
}

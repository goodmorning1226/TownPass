import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:townpass_portal_assistant/service/page_translation.dart';

/// Debug-only entry point that runs the App's page translation on a phone
/// or emulator, so ML Kit's real output can be reviewed on the computer
/// (portal_assistant/scripts/review_translations.py; portal_assistant/docs/AI_PAGE_TRANSLATION.md). Not part of
/// the App: it is only started with `flutter run -t` and replaces the App on
/// the device until the App is installed again.
///
///     python -X utf8 portal_assistant/tools/page_translation_review/serve.py job.json out.json
///     adb reverse tcp:8897 tcp:8897
///     fvm flutter run -t portal_assistant/tools/page_translation_review/mlkit_review.dart -d <device>
///
/// The job ({languages, items: [{text, mode}], back}) is fetched from
/// http://127.0.0.1:8897/job and the results so far are posted to /results
/// after every language (the last post has `done`). Modes:
/// `raw` = ML Kit alone (what the pages showed before 2026-11-13), `glossary`
/// = ML Kit with the glossary's words protected (PageTranslation.translateFresh),
/// `pipeline` = the App's lookup order without this phone's learned cache
/// (pre-translations, glossary, then ML Kit with protection). With `back`,
/// every result is also translated back into Chinese for comparison.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final status = ValueNotifier('loading');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, text, _) => Text(text, textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  );
  final client = HttpClient();
  const base = 'http://127.0.0.1:8897';
  try {
    final request = await client.getUrl(Uri.parse('$base/job'));
    final job = jsonDecode(
      await (await request.close()).transform(utf8.decoder).join(),
    ) as Map<String, dynamic>;
    final translation = PageTranslation.instance;
    await translation.load();
    final languages = (job['languages'] as List).cast<String>();
    final items = (job['items'] as List).cast<Map<String, dynamic>>();
    final back = job['back'] == true;
    final results = <Map<String, dynamic>>[];
    for (final language in languages) {
      var done = 0;
      for (final item in items) {
        final text = item['text'] as String;
        final mode = item['mode'] as String;
        String? out;
        try {
          out = switch (mode) {
            'raw' => await translation.translateFresh(
              text,
              language,
              protect: false,
            ),
            'glossary' => await translation.translateFresh(text, language),
            _ =>
              translation.preset(text, language) ??
                  await translation.translateFresh(text, language),
          };
        } catch (error) {
          out = null;
        }
        final backText = back && out != null
            ? await translation.translateBetween(out, from: language, to: 'zh')
            : null;
        results.add({
          'language': language,
          'mode': mode,
          'text': text,
          'translation': out,
          'back': backText,
        });
        status.value = '$language ${++done}/${items.length}';
      }
      // Sent after every language, so a later failure keeps what is done.
      await _post(client, '$base/results', {
        'results': results,
        'glossaryVersion': translation.glossary.version,
        'misses': translation.glossaryMisses,
        'done': language == languages.last,
      });
    }
    status.value = 'done: ${results.length} translations sent';
  } catch (error) {
    status.value = 'failed: $error';
  } finally {
    client.close();
  }
}

/// Posts [body] as JSON with its length (the server reads Content-Length).
Future<void> _post(HttpClient client, String url, Object body) async {
  final bytes = utf8.encode(jsonEncode(body));
  final post = await client.postUrl(Uri.parse(url));
  post.headers.contentType = ContentType.json;
  post.contentLength = bytes.length;
  post.add(bytes);
  final response = await post.close();
  await response.drain<void>();
  if (response.statusCode >= 300) {
    throw HttpException('results not saved (${response.statusCode})');
  }
}

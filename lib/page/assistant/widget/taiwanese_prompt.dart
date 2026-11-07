import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
import 'package:town_pass/util/tp_button.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// The first time the assistant opens on a Chinese phone it asks, in large
/// text, whether the user speaks Taiwanese (owner, 2026-11-08). "是" picks 台語
/// in the speech-language menu, which is saved, so later launches listen in
/// Taiwanese; "不是" keeps the current choice. Either answer is remembered and
/// the question is not asked again; closing it without an answer asks next time.
/// The menu (and AI 助理設定 → 助理語言) can still change it at any time.
class TaiwanesePrompt {
  TaiwanesePrompt._();

  static const key = 'assistant_taiwanese_asked';
  static bool _showing = false;

  /// Off under `flutter test` (the other tests open the assistant and must not
  /// meet this dialog); the prompt's own tests turn it on.
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  /// Asks unless already answered, the texts are not Chinese, or 台語 is
  /// already chosen. [choose] applies the menu choice (the controller's
  /// setSpeechLanguage).
  static Future<void> maybeAsk({
    required String currentLanguage,
    required void Function(String code) choose,
  }) async {
    if (!enabled || _showing || AssistantTexts.pageLanguage != 'zh') return;
    if (currentLanguage == AssistantSpeechLanguage.taiwanese.code) return;
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(key) == true) return;
    } catch (_) {
      return;
    }
    _showing = true;
    try {
      final taiwanese = await Get.dialog<bool>(
        const _TaiwaneseDialog(),
        barrierDismissible: true,
      );
      if (taiwanese == null) return;
      await prefs.setBool(key, true);
      if (taiwanese) choose(AssistantSpeechLanguage.taiwanese.code);
    } catch (_) {
    } finally {
      _showing = false;
    }
  }

  /// Tests only.
  static void reset() => _showing = false;
}

class _TaiwaneseDialog extends StatelessWidget {
  const _TaiwaneseDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                '您是否為台語用戶？',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 30,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: TPColors.grayscale950,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const TPText(
              '選「是」，助理會用台語聽您說話。之後可以在麥克風旁的語言選單更改。',
              style: TPTextStyles.h3Regular,
              color: TPColors.grayscale700,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 56,
              child: TPButton.primary(
                text: '是，我說台語',
                onPressed: () => Get.back(result: true),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: TPButton.secondary(
                text: '不是',
                onPressed: () => Get.back(result: false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

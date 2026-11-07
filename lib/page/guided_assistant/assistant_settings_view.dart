import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/assistant_settings.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_text.dart';

/// AI 助理設定: assistant mode, assistant language and the tutorial replay.
/// Each change is saved at once (a toast says what changed).
///
/// The language here is the speech-language menu's choice (the menu next to
/// the microphone): one setting for the language the assistant listens in
/// and the one its texts and guides use. The page shows its own texts in
/// that language (gt), so ML Kit page translation is off here.
class AssistantSettingsView extends StatelessWidget {
  const AssistantSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<GuidedAssistantController>();
    return PageTranslationScope(
      enabled: false,
      child: Obx(
        () => Scaffold(
          backgroundColor: TPColors.grayscale50,
          appBar: TPAppBar(title: gt(SettingsTexts.title)),
          body: SafeArea(
            child: ListView(
              // Room below for the assistant button.
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                _summary(c),
                _header(gt(SettingsTexts.modeHeader)),
                _group(gt(SettingsTexts.modeHeader), [
                  for (final m in AssistantMode.values)
                    _OptionRow(
                      title: gt(m.title),
                      desc: gt(m.desc),
                      isDefault: m.isDefault,
                      checked: c.mode.value == m,
                      onTap: () => c.setMode(m),
                    ),
                ]),
                _header(
                  gt(SettingsTexts.langHeader),
                  desc: gt(SettingsTexts.langDesc),
                ),
                _group(gt(SettingsTexts.langHeader), [
                  for (final l in AssistantSpeechLanguage.all)
                    _OptionRow(
                      key: Key('assistant-language-${l.code}'),
                      title: l.title,
                      desc: l.desc,
                      isDefault:
                          l.code == AssistantSpeechLanguage.systemDefault(),
                      checked: c.speechLanguage.value == l.code,
                      onTap: () => c.chooseLanguage(l.code),
                    ),
                ]),
                _whatChanges(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: TPColors.white,
                            side: const BorderSide(color: TPColors.primary500),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: c.replayTutorial,
                          child: TPText(
                            gt(SettingsTexts.replay),
                            style: TPTextStyles.h3Regular,
                            color: TPColors.primary700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TPText(
                        gt(SettingsTexts.replayNote),
                        style: TPTextStyles.bodyRegular.copyWith(fontSize: 13),
                        color: TPColors.grayscale700,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _summary(GuidedAssistantController c) => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: TPColors.white,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        const PenguinAvatar(size: 40, borderWidth: 2),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TPText(
                gt(SettingsTexts.summaryLabel),
                style: TPTextStyles.bodyRegular.copyWith(fontSize: 13),
                color: TPColors.grayscale700,
              ),
              TPText(
                gt('{mode}　＋　{language}', {
                  'mode': gt(c.mode.value.title),
                  'language': AssistantSpeechLanguage.of(c.speechLanguage.value)
                      .title,
                }),
                style: TPTextStyles.h3SemiBold,
                color: TPColors.grayscale950,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _header(String title, {String? desc}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: TPText(
            title,
            style: TPTextStyles.h3SemiBold,
            color: TPColors.grayscale700,
          ),
        ),
        if (desc != null) ...[
          const SizedBox(height: 2),
          TPText(
            desc,
            style: TPTextStyles.bodyRegular,
            color: TPColors.grayscale700,
          ),
        ],
      ],
    ),
  );

  Widget _group(String label, List<Widget> rows) => Semantics(
    label: label,
    container: true,
    child: ColoredBox(
      color: TPColors.white,
      child: Column(children: rows),
    ),
  );

  Widget _whatChanges() {
    final line = TPTextStyles.bodyRegular.copyWith(height: 21 / 14);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: TPColors.primary50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TPText(
            gt(SettingsTexts.whatChanges),
            style: TPTextStyles.h3SemiBold.copyWith(fontSize: 15),
            color: TPColors.grayscale950,
          ),
          const SizedBox(height: 6),
          TPText(
            gt(SettingsTexts.change1),
            style: line,
            color: TPColors.grayscale800,
          ),
          const SizedBox(height: 6),
          TPText(
            gt(SettingsTexts.change2),
            style: line,
            color: TPColors.grayscale800,
          ),
          const SizedBox(height: 6),
          TPText(
            gt(SettingsTexts.change3),
            style: line,
            color: TPColors.grayscale800,
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  final String title;
  final String desc;
  final bool isDefault;
  final bool checked;
  final VoidCallback onTap;

  const _OptionRow({
    super.key,
    required this.title,
    required this.desc,
    required this.isDefault,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = checked ? TPColors.primary500 : TPColors.grayscale950;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: checked,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: TPColors.grayscale100)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TPText(
                          title,
                          style: checked
                              ? TPTextStyles.h3SemiBold
                              : TPTextStyles.h3Regular,
                          color: titleColor,
                        ),
                        if (isDefault)
                          SettingsTag(
                            gt(SettingsTexts.defaultTag),
                            background: TPColors.primary50,
                            color: TPColors.primary700,
                          ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    TPText(
                      desc,
                      style: TPTextStyles.bodyRegular,
                      color: TPColors.grayscale700,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Radio(checked: checked),
            ],
          ),
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  final bool checked;
  const _Radio({required this.checked});

  @override
  Widget build(BuildContext context) {
    if (checked) {
      return Container(
        width: 22,
        height: 22,
        decoration: const BoxDecoration(
          color: TPColors.primary500,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, color: TPColors.white, size: 16),
      );
    }
    return Container(
      width: 20,
      height: 20,
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: TPColors.grayscale200, width: 1.6),
      ),
    );
  }
}

/// Small pill tag (預設, 新增).
class SettingsTag extends StatelessWidget {
  final String text;
  final Color background;
  final Color color;
  const SettingsTag(
    this.text, {
    super.key,
    this.background = TPColors.secondary100,
    this.color = TPColors.secondary800,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(9),
    ),
    child: TPText(
      text,
      style: TPTextStyles.bodyRegular.copyWith(fontSize: 12, height: 18 / 12),
      color: color,
    ),
  );
}

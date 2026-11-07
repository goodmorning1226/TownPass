import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Full-screen assistant: header, current task with its to-do list, chat,
/// chips and the hold-to-talk button.
class GuidedAssistantSheet extends StatefulWidget {
  final GuidedAssistantController controller;
  const GuidedAssistantSheet({super.key, required this.controller});

  @override
  State<GuidedAssistantSheet> createState() => _GuidedAssistantSheetState();
}

class _GuidedAssistantSheetState extends State<GuidedAssistantSheet> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  Worker? _worker;

  GuidedAssistantController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _worker = everAll([c.messages, c.loading], (_) => _toBottom());
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _worker?.dispose();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    _input.clear();
    c.submit(text);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TPColors.white,
      child: SafeArea(
        child: Obx(
          () => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              if (c.task.value != null) _taskCard(c.task.value!),
              Expanded(child: _chat()),
              _bottom(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => SizedBox(
    height: 56,
    child: Row(
      children: [
        const SizedBox(width: 20),
        const Expanded(
          child: TPText(
            '助理',
            style: TPTextStyles.h2SemiBold,
            color: TPColors.primary700,
          ),
        ),
        TextButton(
          onPressed: c.replayOnboarding,
          child: const TPText(
            '重看新手提示',
            style: TPTextStyles.bodyRegular,
            color: TPColors.primary700,
          ),
        ),
        IconButton(
          tooltip: c.readAloud.value ? '朗讀已開啟' : '朗讀已關閉',
          onPressed: c.toggleReadAloud,
          icon: Icon(
            c.readAloud.value
                ? Icons.volume_up_outlined
                : Icons.volume_off_outlined,
            color: TPColors.grayscale700,
          ),
        ),
        IconButton(
          tooltip: '關閉助理',
          onPressed: c.closeSheet,
          icon: const Icon(Icons.close_rounded, color: TPColors.grayscale700),
        ),
        const SizedBox(width: 4),
      ],
    ),
  );

  Widget _taskCard(GuideTask t) {
    final step = c.stepIndex;
    final rows = <Widget>[];
    rows.add(_todoRow(t.guide.openedLabel, _TodoState.done, tag: '完成'));
    for (var i = 0; i < t.guide.steps.length; i++) {
      final s = i < step
          ? _TodoState.done
          : i == step
          ? _TodoState.current
          : _TodoState.todo;
      rows.add(
        _todoRow(
          t.guide.steps[i].label,
          s,
          tag: s == _TodoState.done
              ? '完成'
              : s == _TodoState.current
              ? '進行中'
              : null,
          commit: t.guide.steps[i].commit,
        ),
      );
    }
    final allDone = step >= t.guide.steps.length;
    for (var i = 0; i < t.guide.selfItems.length; i++) {
      rows.add(
        _todoRow(
          t.guide.selfItems[i],
          allDone && i == 0 ? _TodoState.current : _TodoState.todo,
          self: true,
          tag: allDone && i == 0 ? '輪到你確認' : '你自己確認',
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        border: Border.all(color: TPColors.grayscale200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => c.todoOpen.value = !c.todoOpen.value,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Row(
                children: [
                  const Icon(
                    Icons.assignment_turned_in_outlined,
                    color: TPColors.primary700,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TPText(
                      '目前任務：${t.guide.title}',
                      style: TPTextStyles.h3SemiBold,
                      color: TPColors.grayscale950,
                    ),
                  ),
                  _Tag(c.taskTag),
                  const SizedBox(width: 4),
                  Icon(
                    c.todoOpen.value
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: TPColors.grayscale700,
                  ),
                ],
              ),
            ),
          ),
          if (c.todoOpen.value) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: rows),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: TPColors.primary500),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: c.taskSecondary,
                        child: TPText(
                          c.taskSecondaryLabel,
                          style: TPTextStyles.h3Regular,
                          color: TPColors.primary700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: TPColors.primary500,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: c.backToPage,
                        child: TPText(
                          '回到${t.guide.pageName}',
                          style: TPTextStyles.h3Regular,
                          color: TPColors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _todoRow(
    String text,
    _TodoState s, {
    String? tag,
    bool self = false,
    bool commit = false,
  }) {
    Widget icon;
    switch (s) {
      case _TodoState.done:
        icon = const Icon(
          Icons.check_circle,
          color: TPColors.primary600,
          size: 22,
        );
      case _TodoState.current:
        icon = const Icon(
          Icons.radio_button_checked,
          color: TPColors.primary700,
          size: 22,
        );
      case _TodoState.todo:
        icon = const Icon(
          Icons.radio_button_unchecked,
          color: TPColors.grayscale400,
          size: 22,
        );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 10),
          Expanded(
            child: TPText(
              commit ? '$text（會真的送出）' : text,
              style: s == _TodoState.current
                  ? TPTextStyles.h3SemiBold
                  : TPTextStyles.h3Regular,
              color: s == _TodoState.done
                  ? TPColors.grayscale700
                  : TPColors.grayscale950,
            ),
          ),
          if (tag != null) _Tag(tag, self: self),
        ],
      ),
    );
  }

  Widget _chat() => ColoredBox(
    color: TPColors.grayscale50,
    child: ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      children: [
        for (final m in c.messages) _bubble(m),
        if (c.loading.value)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: TPColors.primary700,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: TPText(
                    '正在幫你找…',
                    style: TPTextStyles.h3Regular,
                    color: TPColors.grayscale800,
                  ),
                ),
                TextButton(
                  onPressed: c.cancelLoading,
                  child: const TPText(
                    '取消',
                    style: TPTextStyles.h3SemiBold,
                    color: TPColors.primary700,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _bubble(ChatMessage m) {
    if (m.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10, left: 60),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: TPColors.primary500,
            borderRadius: BorderRadius.circular(16),
          ),
          child: TPText(
            m.text,
            style: TPTextStyles.h3Regular,
            color: TPColors.white,
          ),
        ),
      );
    }
    final parts = <Widget>[
      TPText(
        m.text,
        style: TPTextStyles.h3Regular,
        color: TPColors.grayscale950,
      ),
    ];
    final term = m.term;
    if (term != null) {
      parts.add(
        TPText(
          term.title,
          style: TPTextStyles.bodySemiBold,
          color: TPColors.primary700,
        ),
      );
      if (term.showsBill) parts.add(const _BillIllustration());
      parts.add(
        TPText(
          '例如：${term.example}',
          style: TPTextStyles.bodyRegular,
          color: TPColors.grayscale700,
        ),
      );
    }
    final options = m.options;
    if (options != null) {
      final live = c.optionsLive(m);
      var n = 1;
      for (final o in options.options) {
        final number = n++;
        parts.add(
          _OptionButton(
            label: '$number. ${o.label}${o.enabled ? '' : '（還不能用）'}',
            enabled: live && o.enabled,
            dimmed: !o.enabled,
            onTap: live ? () => c.choose(m, o) : null,
          ),
        );
      }
      if (m.followUpOf == null) {
        parts.add(
          _OptionButton(
            label: '$n. 都不是，我再說一次',
            enabled: live,
            onTap: live ? () => c.choose(m, null) : null,
          ),
        );
      }
    }
    final answer = m.answer;
    if (answer != null) parts.add(_AnswerCard(answer));
    final teach = m.teachGuideId;
    if (teach != null && c.optionsLive(m)) {
      parts.add(
        _OptionButton(
          label: '教我',
          enabled: true,
          onTap: () => c.startGuide(teach),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10, right: 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: TPColors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              parts[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _bottom(BuildContext context) {
    final chips = c.chips;
    return Container(
      color: TPColors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chips.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final chip in chips)
                  SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: TPColors.primary500),
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      onPressed: () => c.submit(chip),
                      child: TPText(
                        chip,
                        style: TPTextStyles.h3Regular,
                        color: TPColors.primary700,
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          if (c.typing.value) _typingRow() else _micRow(),
        ],
      ),
    );
  }

  Widget _micRow() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 80,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Semantics(
              button: true,
              label: '按住說話（示範）',
              child: Listener(
                onPointerDown: (_) => c.micDown(),
                onPointerUp: (_) => c.micUp(),
                onPointerCancel: (_) => c.micUp(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: c.listening.value ? 80 : 72,
                  height: c.listening.value ? 80 : 72,
                  decoration: BoxDecoration(
                    color: c.listening.value
                        ? TPColors.primary700
                        : TPColors.primary500,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.mic_none_rounded,
                    color: TPColors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              child: IconButton(
                tooltip: '改用鍵盤輸入',
                iconSize: 28,
                onPressed: () => c.typing.value = true,
                icon: const Icon(
                  Icons.keyboard_outlined,
                  color: TPColors.grayscale800,
                ),
              ),
            ),
          ],
        ),
      ),
      TPText(
        c.listening.value ? '放開送出' : '按住說話，或點上面的選項',
        style: TPTextStyles.bodyRegular,
        color: TPColors.grayscale700,
      ),
    ],
  );

  Widget _typingRow() => Row(
    children: [
      IconButton(
        tooltip: '改用語音',
        onPressed: () => c.typing.value = false,
        icon: const Icon(Icons.mic_none_rounded, color: TPColors.grayscale800),
      ),
      Expanded(
        child: TextField(
          controller: _input,
          autofocus: true,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _send(),
          style: TPTextStyles.h3Regular.copyWith(color: TPColors.grayscale950),
          decoration: InputDecoration(
            hintText: '打字告訴我你想做什麼',
            hintStyle: TPTextStyles.h3Regular.copyWith(
              color: TPColors.grayscale400,
            ),
            filled: true,
            fillColor: TPColors.grayscale50,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 13,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: '送出',
        onPressed: _send,
        icon: const Icon(Icons.send_rounded, color: TPColors.primary600),
      ),
    ],
  );
}

enum _TodoState { done, current, todo }

class _Tag extends StatelessWidget {
  final String text;
  final bool self;
  const _Tag(this.text, {this.self = false});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: self ? TPColors.secondary100 : TPColors.primary100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: TPText(
        text,
        style: TPTextStyles.bodySemiBold,
        color: self ? TPColors.secondary800 : TPColors.primary700,
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool dimmed;
  final VoidCallback? onTap;
  const _OptionButton({
    required this.label,
    required this.enabled,
    this.dimmed = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        side: BorderSide(
          color: dimmed || !enabled
              ? TPColors.grayscale200
              : TPColors.primary500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      // Disabled options stay tappable so the user hears why.
      onPressed: onTap,
      child: TPText(
        label,
        style: TPTextStyles.h3Regular,
        color: dimmed || !enabled ? TPColors.grayscale500 : TPColors.primary700,
      ),
    );
  }
}

class _BillIllustration extends StatelessWidget {
  const _BillIllustration();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '水費帳單示意圖，水號印在帳單上方',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: TPColors.grayscale200),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TPText(
              '水費帳單（示意）',
              style: TPTextStyles.bodyRegular,
              color: TPColors.grayscale700,
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: guideYellow, width: 3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  TPText(
                    '水號',
                    style: TPTextStyles.bodySemiBold,
                    color: TPColors.grayscale950,
                  ),
                  SizedBox(width: 8),
                  TPText(
                    '1-23-456789-0',
                    style: TPTextStyles.h3Regular,
                    color: TPColors.grayscale950,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            FractionallySizedBox(
              widthFactor: 0.7,
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  color: TPColors.grayscale100,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 6),
            FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  color: TPColors.grayscale100,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerCard extends StatelessWidget {
  final AnswerCardContent content;
  const _AnswerCard(this.content);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: TPColors.grayscale200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TPText(
            content.title,
            style: TPTextStyles.h3SemiBold,
            color: TPColors.grayscale950,
          ),
          const SizedBox(height: 8),
          for (final p in content.places)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TPText(
                    '${p.name}　${p.distance}',
                    style: TPTextStyles.h3SemiBold,
                    color: TPColors.grayscale950,
                  ),
                  TPText(
                    p.address,
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.grayscale700,
                  ),
                  TPText(
                    '電話 ${p.phone}',
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.grayscale700,
                  ),
                ],
              ),
            ),
          TPText(
            content.source,
            style: TPTextStyles.bodyRegular,
            color: TPColors.secondary800,
          ),
        ],
      ),
    );
  }
}

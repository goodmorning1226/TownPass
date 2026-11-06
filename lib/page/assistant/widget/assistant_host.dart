import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/assistant/assistant_view_controller.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Root overlay: the original Navigator and native WebView remain the page UI.
/// Collapsed it is a corner "助理" button with a short hint; opened it covers
/// the screen with a translucent conversation sheet.
class AssistantHost extends StatefulWidget {
  final Widget child;
  final AssistantViewController controller;
  const AssistantHost({
    super.key,
    required this.child,
    required this.controller,
  });

  @override
  State<AssistantHost> createState() => _AssistantHostState();
}

class _AssistantHostState extends State<AssistantHost> {
  late final OverlayEntry _entry = OverlayEntry(builder: _buildHost);
  bool _left = false;

  @override
  void didUpdateWidget(covariant AssistantHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);

  Widget _buildHost(BuildContext context) {
    final controller = widget.controller;
    return Stack(
      children: [
        widget.child,
        Obx(() {
          if (controller.hidden.value) return const SizedBox.shrink();
          if (controller.expanded.value) {
            return Positioned.fill(
              child: AssistantSheet(controller: controller),
            );
          }
          return _corner(context, controller);
        }),
      ],
    );
  }

  Widget _corner(BuildContext context, AssistantViewController controller) {
    final media = MediaQuery.of(context);
    final hint = controller.cornerMessageId.value;
    return Positioned(
      left: _left ? 16 : null,
      right: _left ? null : 16,
      bottom: math.max(
        media.padding.bottom + 145,
        media.viewInsets.bottom + 16,
      ),
      child: SizedBox(
        width: math.min(300, media.size.width - 32),
        child: Column(
          crossAxisAlignment: _left
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hint != null)
              Semantics(
                liveRegion: true,
                button: true,
                hint: '開啟助理對話',
                child: Material(
                  color: TPColors.white,
                  elevation: 3,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    key: const Key('assistant-corner-hint'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => controller.openPanel(scrollTo: hint),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: TPText(
                        controller.message.value,
                        style: TPTextStyles.bodyRegular,
                        color: TPColors.grayscale800,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            GestureDetector(
              onLongPress: () {
                _left = !_left;
                _entry.markNeedsBuild();
              },
              child: FloatingActionButton.extended(
                heroTag: 'townpass-assistant',
                tooltip: '開啟助理，長按可移到另一側',
                backgroundColor: TPColors.primary500,
                foregroundColor: TPColors.white,
                onPressed: controller.openPanel,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('助理'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen conversation. The page underneath stays faintly visible but
/// cannot be touched; history lives in the controller, not in this widget.
class AssistantSheet extends StatefulWidget {
  final AssistantViewController controller;
  const AssistantSheet({super.key, required this.controller});

  @override
  State<AssistantSheet> createState() => _AssistantSheetState();
}

class _AssistantSheetState extends State<AssistantSheet> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  late final Worker _onMessages;
  bool _keyboard = !AssistantViewController.voiceInputAvailable;
  bool _voiceNotice = false;

  AssistantViewController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _onMessages = ever(controller.messages, (_) => _scrollTo(null));
    _scrollTo(controller.scrollTarget.value);
  }

  @override
  void dispose() {
    _onMessages.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls to a message, or to the newest one when [id] is null.
  void _scrollTo(int? id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = id == null ? null : _keys[id]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.1);
        controller.scrollTarget.value = null;
      } else {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _send([String? value]) {
    final text = value ?? _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    controller.submit(text);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: Material(
        color: TPColors.white.withValues(alpha: 0.9),
        child: Padding(
          padding: EdgeInsets.only(
            top: media.padding.top,
            bottom: math.max(media.viewInsets.bottom, media.padding.bottom),
          ),
          child: Column(
            children: [
              _header(),
              Expanded(
                child: Obx(
                  () => controller.messages.isEmpty && !controller.busy.value
                      ? _suggestions()
                      : _conversation(),
                ),
              ),
              _keyboard ? _keyboardBar() : _voiceBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
    child: Row(
      children: [
        const Expanded(
          child: TPText(
            '助理',
            style: TPTextStyles.h2SemiBold,
            color: TPColors.primary700,
          ),
        ),
        IconButton(
          tooltip: '關閉助理',
          iconSize: 28,
          onPressed: controller.closePanel,
          icon: const Icon(Icons.close, color: TPColors.grayscale700),
        ),
      ],
    ),
  );

  Widget _suggestions() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    children: [
      const TPText(
        '你可以說…',
        style: TPTextStyles.h3SemiBold,
        color: TPColors.grayscale800,
      ),
      const SizedBox(height: 12),
      for (final suggestion in AssistantViewController.suggestions)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _OutlinedChoice(
            title: '「${suggestion.text}」',
            onTap: () => _send(suggestion.text),
          ),
        ),
      const SizedBox(height: 8),
      const TPText(
        '我會帶你到原本的服務頁面。示範與未串接功能會標示，送出與付款由你自己確認。',
        style: TPTextStyles.bodyRegular,
        color: TPColors.grayscale600,
      ),
    ],
  );

  Widget _conversation() => ListView(
    controller: _scroll,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    children: [
      for (final item in controller.messages) _bubble(item),
      if (controller.busy.value) _busyRow(),
    ],
  );

  Widget _bubble(AssistantChatMessage item) {
    final key = _keys.putIfAbsent(item.id, GlobalKey.new);
    final selectable = controller.choicesMessageId.value == item.id;
    return Padding(
      key: key,
      padding: EdgeInsets.only(
        bottom: 10,
        left: item.fromUser ? 0 : 12,
        right: item.fromUser ? 48 : 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: item.fromUser ? '你說' : '助理回覆',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: item.fromUser ? TPColors.primary500 : TPColors.white,
                borderRadius: BorderRadius.circular(16),
                border: item.fromUser
                    ? null
                    : Border.all(color: TPColors.grayscale200),
              ),
              child: TPText(
                item.text,
                style: TPTextStyles.h3Regular,
                color: item.fromUser ? TPColors.white : TPColors.grayscale900,
              ),
            ),
          ),
          if (selectable)
            for (final choice in item.choices)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _OutlinedChoice(
                  title: choice.title,
                  subtitle: choice.subtitle,
                  onTap: choice.enabled
                      ? () => controller.choose(choice)
                      : null,
                ),
              ),
        ],
      ),
    );
  }

  Widget _busyRow() => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: TPColors.primary500,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(child: TPText('正在處理…', color: TPColors.grayscale700)),
        TextButton(onPressed: controller.cancel, child: const Text('取消')),
      ],
    ),
  );

  Widget _keyboardBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Obx(
            () => TextField(
              key: const Key('assistant-input'),
              controller: _input,
              enabled: !controller.busy.value,
              maxLength: 500,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: '輸入想做的事，例如：我要借書',
                counterText: '',
                filled: true,
                fillColor: TPColors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: TPColors.grayscale200),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: TPColors.primary500),
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
        ),
        IconButton(
          tooltip: '送出',
          iconSize: 28,
          color: TPColors.primary500,
          onPressed: () => _send(),
          icon: const Icon(Icons.send),
        ),
        IconButton(
          tooltip: '改用語音',
          iconSize: 28,
          color: TPColors.grayscale700,
          onPressed: () => setState(() {
            _keyboard = false;
            _voiceNotice = false;
          }),
          icon: const Icon(Icons.mic_none),
        ),
      ],
    ),
  );

  Widget _voiceBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: '按住說話',
              child: GestureDetector(
                onLongPressStart: (_) => setState(() => _voiceNotice = true),
                child: Material(
                  color: TPColors.primary500,
                  shape: const CircleBorder(),
                  elevation: 4,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _voiceNotice = true),
                    child: const SizedBox(
                      width: 88,
                      height: 88,
                      child: Icon(Icons.mic, color: TPColors.white, size: 40),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TPText(
              _voiceNotice ? '語音輸入下一階段開放，請先點右下鍵盤用打字。' : '按住說話',
              style: TPTextStyles.bodyRegular,
              color: TPColors.grayscale700,
              textAlign: TextAlign.center,
            ),
          ],
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: IconButton(
            tooltip: '改用鍵盤',
            iconSize: 30,
            color: TPColors.grayscale700,
            onPressed: () => setState(() => _keyboard = true),
            icon: const Icon(Icons.keyboard_alt_outlined),
          ),
        ),
      ],
    ),
  );
}

/// A full-width bordered option in the TownPass primary colour.
class _OutlinedChoice extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  const _OutlinedChoice({required this.title, this.subtitle = '', this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: TPColors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: enabled ? TPColors.primary500 : TPColors.grayscale200,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TPText(
                title,
                style: TPTextStyles.h3SemiBold,
                color: enabled ? TPColors.primary700 : TPColors.grayscale500,
              ),
              if (subtitle.isNotEmpty)
                TPText(
                  subtitle,
                  style: TPTextStyles.bodyRegular,
                  color: TPColors.grayscale600,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

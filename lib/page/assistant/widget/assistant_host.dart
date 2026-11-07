import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/assistant/assistant_view_controller.dart';
import 'package:town_pass/service/assistant_speech_language.dart';
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
  bool _pressed = false;
  bool _discard = false;
  Offset? _pressOrigin;

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
        Obx(
          () => IconButton(
            tooltip: controller.readAloud.value
                ? '朗讀回覆：開（點一下關閉）'
                : '朗讀回覆：關（點一下開啟）',
            iconSize: 28,
            onPressed: () =>
                controller.setReadAloud(!controller.readAloud.value),
            icon: Icon(
              controller.readAloud.value ? Icons.volume_up : Icons.volume_off,
              color: controller.readAloud.value
                  ? TPColors.primary500
                  : TPColors.grayscale500,
            ),
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
      // The user's messages sit on the right, the assistant's on the left.
      padding: EdgeInsets.only(
        bottom: 10,
        left: item.fromUser ? 48 : 0,
        right: item.fromUser ? 0 : 48,
      ),
      child: Column(
        crossAxisAlignment: item.fromUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
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
            for (final (index, choice) in item.choices.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _OutlinedChoice(
                  number: index + 1,
                  title: choice.title,
                  subtitle: choice.subtitle,
                  onTap: choice.enabled
                      ? () => controller.choose(choice)
                      : null,
                ),
              ),
          if (selectable)
            for (final (index, suggestion) in item.suggestions.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _OutlinedChoice(
                  number: index + 1,
                  title: '「$suggestion」',
                  onTap: () => controller.chooseSuggestion(suggestion),
                ),
              ),
          if (selectable &&
              (item.choices.isNotEmpty || item.suggestions.isNotEmpty))
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 4),
              child: TPText(
                '可以點選，或說出／打出編號，例如「第 1 個」。',
                style: TPTextStyles.bodyRegular,
                color: TPColors.grayscale600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _busyRow() => Padding(
    padding: const EdgeInsets.only(right: 48),
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
          onPressed: () => setState(() => _keyboard = false),
          icon: const Icon(Icons.mic_none),
        ),
      ],
    ),
  );

  /// Hold to record, release to send, slide up to discard. With a screen
  /// reader a double-tap starts and a second double-tap sends.
  Widget _voiceBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Obx(() {
      final listening = controller.listening.value;
      final busy = controller.busy.value;
      final quiet = controller.tooQuiet.value;
      final caption = listening
          ? (_discard
                ? '放開取消'
                : quiet
                ? '聲音有點小，請靠近麥克風說'
                : '放開送出，往上滑可取消')
          : busy
          ? '處理中，可在上方取消'
          : '按住說話';
      final downloading = controller.speechDownloading.value;
      final percent = controller.speechDownloadPercent.value;
      final bar = Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Speech language (Whisper builds; the phone's own recogniser is
          // Chinese only for now).
          Expanded(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: controller.systemSpeech == null
                  ? _languageButton(listening || busy)
                  : const SizedBox.shrink(),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: listening ? '正在聽，點兩下送出' : '按住說話',
                onTap: busy ? null : _toggleListening,
                excludeSemantics: true,
                child: Listener(
                  onPointerDown: busy ? null : _pressStart,
                  onPointerMove: (event) => _pressMove(event.position),
                  onPointerUp: (_) => _pressEnd(cancelled: false),
                  onPointerCancel: (_) => _pressEnd(cancelled: true),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: listening ? 104 : 88,
                    height: listening ? 104 : 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: busy
                          ? TPColors.grayscale300
                          : listening
                          ? (_discard ? TPColors.grayscale500 : TPColors.red500)
                          : TPColors.primary500,
                      boxShadow: const [
                        BoxShadow(color: Color(0x33000000), blurRadius: 8),
                      ],
                    ),
                    child: Icon(
                      listening ? Icons.graphic_eq : Icons.mic,
                      color: TPColors.white,
                      size: 40,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Live loudness while recording, so a quiet voice is noticed
              // before the clip is sent.
              SizedBox(
                width: 120,
                height: 6,
                child: listening
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          key: const Key('assistant-level'),
                          value: controller.level.value,
                          color: quiet
                              ? TPColors.secondary500
                              : TPColors.primary500,
                          backgroundColor: TPColors.grayscale100,
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 4),
              TPText(
                caption,
                style: TPTextStyles.bodyRegular,
                color: quiet && listening
                    ? TPColors.secondary700
                    : TPColors.grayscale700,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          Expanded(
            child: Align(
              alignment: Alignment.bottomRight,
              child: IconButton(
                tooltip: '改用鍵盤',
                iconSize: 30,
                color: TPColors.grayscale700,
                onPressed: listening
                    ? null
                    : () => setState(() => _keyboard = true),
                icon: const Icon(Icons.keyboard_alt_outlined),
              ),
            ),
          ),
        ],
      );
      if (!downloading) return bar;
      // The phone's offline speech pack is downloading (phone recogniser only).
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TPText(
            percent == null ? '正在下載中文（台灣）離線語音…' : '正在下載中文（台灣）離線語音 $percent%',
            style: TPTextStyles.bodyRegular,
            color: TPColors.grayscale700,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const Key('assistant-speech-download'),
              value: percent == null ? null : percent / 100,
              minHeight: 6,
              color: TPColors.primary500,
              backgroundColor: TPColors.grayscale100,
            ),
          ),
          const SizedBox(height: 12),
          bar,
        ],
      );
    }),
  );

  /// Speech language menu: "自動偵測" or one language, each in its own script.
  /// With auto, the language last detected is shown after it.
  Widget _languageButton(bool locked) {
    final chosen = AssistantSpeechLanguage.of(controller.speechLanguage.value);
    final heard = controller.heardLanguage.value;
    final label = chosen.code == 'auto' && heard != null
        ? '${chosen.short}·${AssistantSpeechLanguage.of(heard).short}'
        : chosen.short;
    // A MenuAnchor, not a PopupMenuButton: this host sits above the App's
    // Navigator, so a popup route opened underneath the panel and the menu
    // never appeared. MenuAnchor draws in the host's own Overlay.
    return MenuAnchor(
      key: const Key('assistant-speech-language'),
      menuChildren: [
        for (final language in AssistantSpeechLanguage.all)
          MenuItemButton(
            key: Key('assistant-speech-language-${language.code}'),
            onPressed: () => controller.setSpeechLanguage(language.code),
            leadingIcon: Icon(
              language.code == chosen.code ? Icons.check : null,
              size: 20,
            ),
            child: TPText(language.label, style: TPTextStyles.bodyRegular),
          ),
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: '說話的語言：${chosen.label}',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: locked ? null : () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.translate,
                  size: 22,
                  color: TPColors.grayscale700,
                ),
                const SizedBox(width: 4),
                TPText(
                  label,
                  style: TPTextStyles.bodyRegular,
                  color: TPColors.grayscale700,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pressStart(PointerDownEvent event) async {
    _pressOrigin = event.position;
    _pressed = true;
    setState(() => _discard = false);
    final started = await controller.startListening();
    // Released before listening had started (e.g. the first language check):
    // the recording already began, so send it unless the user slid to cancel.
    if (started && !_pressed) await controller.stopListening(send: !_discard);
  }

  void _pressMove(Offset position) {
    final origin = _pressOrigin;
    if (origin == null || !controller.listening.value) return;
    final discard = origin.dy - position.dy > 80;
    if (discard != _discard) setState(() => _discard = discard);
  }

  void _pressEnd({required bool cancelled}) {
    if (!_pressed) return;
    _pressed = false;
    _pressOrigin = null;
    controller.stopListening(send: !cancelled && !_discard);
  }

  void _toggleListening() {
    if (controller.listening.value) {
      controller.stopListening();
    } else {
      controller.startListening();
    }
  }
}

/// A full-width bordered option in the TownPass primary colour.
class _OutlinedChoice extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  /// Shown as a badge so the option can also be chosen by saying its number.
  final int? number;
  const _OutlinedChoice({
    required this.title,
    this.subtitle = '',
    this.onTap,
    this.number,
  });

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
          child: Row(
            children: [
              if (number != null) ...[
                Semantics(
                  label: '第 $number 項',
                  child: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: enabled
                          ? TPColors.primary500
                          : TPColors.grayscale200,
                    ),
                    child: TPText(
                      '$number',
                      style: TPTextStyles.h3SemiBold,
                      color: TPColors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TPText(
                      title,
                      style: TPTextStyles.h3SemiBold,
                      color: enabled
                          ? TPColors.primary700
                          : TPColors.grayscale500,
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
            ],
          ),
        ),
      ),
    );
  }
}

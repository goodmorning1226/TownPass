import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:townpass_portal_assistant/page/assistant/assistant_texts.dart';
import 'package:townpass_portal_assistant/page/assistant/assistant_view_controller.dart';
import 'package:townpass_portal_assistant/page/assistant/widget/model_download_card.dart';
import 'package:townpass_portal_assistant/service/assistant_model_download.dart';
import 'package:townpass_portal_assistant/service/assistant_on_device.dart';
import 'package:townpass_portal_assistant/service/assistant_readiness.dart';
import 'package:townpass_portal_assistant/service/assistant_recent_inputs.dart';
import 'package:townpass_portal_assistant/service/assistant_speech_language.dart';
import 'package:townpass_portal_assistant/service/page_translation.dart';
import 'package:townpass_portal_assistant/host/assistant_ui.dart';

/// Root overlay: the original Navigator and native WebView remain the page UI.
/// Collapsed it is a corner "助理" button with a short hint; opened it covers
/// the screen with a translucent conversation sheet. Its own texts follow the
/// page language ([AssistantTexts]); replies arrive already in theirs.
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
        // The assistant's own texts are not page content (PageTranslation).
        PageTranslationScope(
          enabled: false,
          child: Obx(() {
            if (controller.hidden.value) return const SizedBox.shrink();
            if (controller.expanded.value) {
              return Positioned.fill(
                child: AssistantSheet(controller: controller),
              );
            }
            return _corner(context, controller);
          }),
        ),
        // First use of a page language downloads its translation model:
        // below the title bar (portal_assistant/docs/AI_CURRENT_RULES.md section 5).
        Obx(() {
          final translation = PageTranslation.instance;
          if (!translation.preparing.value) return const SizedBox.shrink();
          return Positioned(
            left: 16,
            right: 16,
            top: translationBannerTop(context),
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AssistantColors.grayscale900.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AssistantText(
                  AssistantTexts.text(
                    'downloadingTranslation',
                    translation.language.value,
                  ),
                  style: AssistantTextStyles.bodyRegular,
                  color: AssistantColors.white,
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _corner(BuildContext context, AssistantViewController controller) {
    final media = MediaQuery.of(context);
    // Read inside the host's Obx, so the corner follows the page language.
    final language = AssistantTexts.pageLanguage;
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
                hint: AssistantTexts.text('openHint', language),
                child: Material(
                  color: AssistantColors.white,
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
                      child: AssistantText(
                        controller.message.value,
                        style: AssistantTextStyles.bodyRegular,
                        color: AssistantColors.grayscale800,
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
                tooltip: AssistantTexts.text('openTooltip', language),
                backgroundColor: AssistantColors.primary500,
                foregroundColor: AssistantColors.white,
                onPressed: controller.openPanel,
                icon: const Icon(Icons.chat_bubble_outline),
                label: Text(AssistantTexts.text('title', language)),
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

  /// [key] in the page language. Called while an Obx builds, so the sheet
  /// rebuilds when the page language changes.
  String _t(String key, [Map<String, Object> values = const {}]) =>
      AssistantTexts.page(key, values);

  @override
  Widget build(BuildContext context) => Obx(() => _sheet(context));

  Widget _sheet(BuildContext context) {
    final media = MediaQuery.of(context);
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: Material(
        color: AssistantColors.white.withValues(alpha: 0.9),
        child: Padding(
          padding: EdgeInsets.only(
            top: media.padding.top,
            bottom: math.max(media.viewInsets.bottom, media.padding.bottom),
          ),
          // Inside build's Obx: a change of the download status rebuilds it.
          child: _panel(AssistantModelDownload.maybe),
        ),
      ),
    );
  }

  /// No core models on the phone yet: the download first
  /// (portal_assistant/docs/AI_CURRENT_RULES.md section 7); then the conversation, with a
  /// banner while the decision model is still to come.
  Widget _panel(AssistantModelDownload? downloads) {
    if (downloads != null && downloads.needsCore) {
      return Column(
        children: [
          _header(),
          Expanded(
            child: ModelDownloadCard(
              downloads: downloads,
              onLater: controller.closePanel,
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        _header(),
        if (downloads != null) ModelDownloadBanner(downloads: downloads),
        Expanded(
          child: Obx(
            () => controller.messages.isEmpty && !controller.busy.value
                ? _suggestions()
                : _conversation(),
          ),
        ),
        _keyboard ? _keyboardBar() : _voiceBar(),
      ],
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
    child: Row(
      children: [
        Expanded(
          child: AssistantText(
            _t('title'),
            style: AssistantTextStyles.h2SemiBold,
            color: AssistantColors.primary700,
          ),
        ),
        Obx(
          () => IconButton(
            tooltip: _t(
              controller.readAloud.value ? 'readAloudOn' : 'readAloudOff',
            ),
            iconSize: 28,
            onPressed: () =>
                controller.setReadAloud(!controller.readAloud.value),
            icon: Icon(
              controller.readAloud.value ? Icons.volume_up : Icons.volume_off,
              color: controller.readAloud.value
                  ? AssistantColors.primary500
                  : AssistantColors.grayscale500,
            ),
          ),
        ),
        IconButton(
          tooltip: _t('close'),
          iconSize: 28,
          onPressed: controller.closePanel,
          icon: const Icon(Icons.close, color: AssistantColors.grayscale700),
        ),
      ],
    ),
  );

  Widget _suggestions() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    children: [
      AssistantText(
        _t('youCanSay'),
        style: AssistantTextStyles.h3SemiBold,
        color: AssistantColors.grayscale800,
      ),
      const SizedBox(height: 12),
      // The user's own recent requests that worked, then the defaults.
      // Only the recent requests made in the panel's language (2026-11-16).
      for (final text in AssistantRecentInputs.instance.merged([
        for (final suggestion in AssistantViewController.suggestionsFor(
          AssistantTexts.pageLanguage,
        ))
          suggestion.text,
      ], language: AssistantTexts.pageLanguage))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _OutlinedChoice(
            title: _t('quoted', {'text': text}),
            onTap: () => _send(text),
          ),
        ),
      const SizedBox(height: 8),
      AssistantText(
        _t('intro'),
        style: AssistantTextStyles.bodyRegular,
        color: AssistantColors.grayscale600,
      ),
      // Where recordings, typed text and the history stay (on-device
      // builds; portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-16).
      if (AssistantModelDownload.maybe != null) ...[
        const SizedBox(height: 8),
        AssistantText(
          _t('privacy'),
          key: const Key('assistant-privacy'),
          style: AssistantTextStyles.bodyRegular,
          color: AssistantColors.grayscale600,
        ),
      ],
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
            label: _t(item.fromUser ? 'youSaid' : 'assistantReply'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: item.fromUser ? AssistantColors.primary500 : AssistantColors.white,
                borderRadius: BorderRadius.circular(16),
                border: item.fromUser
                    ? null
                    : Border.all(color: AssistantColors.grayscale200),
              ),
              child: AssistantText(
                item.text,
                style: AssistantTextStyles.h3Regular,
                color: item.fromUser ? AssistantColors.white : AssistantColors.grayscale900,
              ),
            ),
          ),
          if (selectable)
            for (final (index, choice) in item.choices.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _OutlinedChoice(
                  number: index + 1,
                  numberLabel: _t('optionNumber', {'n': index + 1}),
                  title: choice.title,
                  subtitle: choice.subtitle,
                  onTap: choice.enabled
                      ? () => controller.choose(choice)
                      : null,
                ),
              ),
          if (item.listing case final listing?
              when selectable && listing.hasPages && item.choices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AssistantPageRow(
                current: listing.page,
                count: listing.pageCount,
                label: _t,
                onStep: controller.busy.value ? null : controller.turnPage,
              ),
            ),
          if (selectable)
            for (final (index, suggestion) in item.suggestions.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _OutlinedChoice(
                  number: index + 1,
                  numberLabel: _t('optionNumber', {'n': index + 1}),
                  title: _t('quoted', {'text': suggestion}),
                  onTap: () => controller.chooseSuggestion(suggestion),
                ),
              ),
          if (selectable &&
              (item.choices.isNotEmpty || item.suggestions.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: AssistantText(
                _t('chooseHint'),
                style: AssistantTextStyles.bodyRegular,
                color: AssistantColors.grayscale600,
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
            color: AssistantColors.primary500,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          // An iPhone just back from the background: its servers come back first.
          child: ListenableBuilder(
            listenable: Listenable.merge([
              AssistantOnDevice.reconnecting,
              AssistantReadiness.loading,
            ]),
            builder: (_, _) => AssistantText(
              _t(
                AssistantOnDevice.reconnecting.value
                    ? 'reconnecting'
                    : AssistantReadiness.loading.value
                    ? 'modelsLoading'
                    : 'processing',
              ),
              color: AssistantColors.grayscale700,
            ),
          ),
        ),
        TextButton(onPressed: controller.cancel, child: Text(_t('cancel'))),
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
                hintText: _t('inputHint'),
                counterText: '',
                filled: true,
                fillColor: AssistantColors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AssistantColors.grayscale200),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AssistantColors.primary500),
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
        ),
        IconButton(
          tooltip: _t('send'),
          iconSize: 28,
          color: AssistantColors.primary500,
          onPressed: () => _send(),
          icon: const Icon(Icons.send),
        ),
        IconButton(
          tooltip: _t('useVoice'),
          iconSize: 28,
          color: AssistantColors.grayscale700,
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
      final caption = _t(
        listening
            ? (_discard
                  ? 'releaseToCancel'
                  : quiet
                  ? 'tooQuiet'
                  : 'releaseToSend')
            : busy
            ? 'busyCaption'
            : 'holdToTalk',
      );
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
          // Bounded width: a longer caption in another language wraps
          // instead of overflowing the row.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 176),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  button: true,
                  label: _t(listening ? 'listeningSemantics' : 'holdToTalk'),
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
                            ? AssistantColors.grayscale300
                            : listening
                            ? (_discard
                                  ? AssistantColors.grayscale500
                                  : AssistantColors.red500)
                            : AssistantColors.primary500,
                        boxShadow: const [
                          BoxShadow(color: Color(0x33000000), blurRadius: 8),
                        ],
                      ),
                      child: Icon(
                        listening ? Icons.graphic_eq : Icons.mic,
                        color: AssistantColors.white,
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
                                ? AssistantColors.secondary500
                                : AssistantColors.primary500,
                            backgroundColor: AssistantColors.grayscale100,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 4),
                AssistantText(
                  caption,
                  style: AssistantTextStyles.bodyRegular,
                  color: quiet && listening
                      ? AssistantColors.secondary700
                      : AssistantColors.grayscale700,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.bottomRight,
              child: IconButton(
                tooltip: _t('useKeyboard'),
                iconSize: 30,
                color: AssistantColors.grayscale700,
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
          AssistantText(
            percent == null
                ? _t('speechDownloading')
                : _t('speechDownloadingPercent', {'percent': percent}),
            style: AssistantTextStyles.bodyRegular,
            color: AssistantColors.grayscale700,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const Key('assistant-speech-download'),
              value: percent == null ? null : percent / 100,
              minHeight: 6,
              color: AssistantColors.primary500,
              backgroundColor: AssistantColors.grayscale100,
            ),
          ),
          const SizedBox(height: 12),
          bar,
        ],
      );
    }),
  );

  /// Speech language menu: "自動偵測" (in the page language) or one language,
  /// each in its own script. With auto, the language last detected is shown
  /// after it. Texts are read here, not in the menu's builders, so the
  /// enclosing Obx sees them.
  Widget _languageButton(bool locked) {
    final chosen = AssistantSpeechLanguage.of(controller.speechLanguage.value);
    final heard = controller.heardLanguage.value;
    String short(AssistantSpeechLanguage language) =>
        language.code == 'auto' ? _t('autoShort') : language.short;
    String name(AssistantSpeechLanguage language) =>
        language.code == 'auto' ? _t('autoDetect') : language.label;
    final label = chosen.code == 'auto' && heard != null
        ? '${short(chosen)}·${short(AssistantSpeechLanguage.of(heard))}'
        : short(chosen);
    final semantics = _t('speechLanguage', {'language': name(chosen)});
    final names = {
      for (final language in AssistantSpeechLanguage.all)
        language.code: name(language),
    };
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
            child: AssistantText(
              names[language.code]!,
              style: AssistantTextStyles.bodyRegular,
            ),
          ),
      ],
      builder: (context, menu, _) => Semantics(
        button: true,
        label: semantics,
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
                  color: AssistantColors.grayscale700,
                ),
                const SizedBox(width: 4),
                AssistantText(
                  label,
                  style: AssistantTextStyles.bodyRegular,
                  color: AssistantColors.grayscale700,
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

/// ◀ 第 2／11 頁 ▶ under a capability list with more than one page. [onStep]
/// gets -1 or 1; null disables both buttons (a request is on its way).
/// [label] gives the panel's texts (previousPage, nextPage, pageOf).
class AssistantPageRow extends StatelessWidget {
  final int current;
  final int count;
  final String Function(String key, [Map<String, Object> values]) label;
  final void Function(int step)? onStep;
  const AssistantPageRow({
    super.key,
    required this.current,
    required this.count,
    required this.label,
    this.onStep,
  });

  Widget _arrow(IconData icon, String tooltip, int step, Key key) {
    final enabled = onStep != null;
    return IconButton(
      key: key,
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      style: IconButton.styleFrom(
        backgroundColor: AssistantColors.white,
        disabledBackgroundColor: AssistantColors.white,
        side: BorderSide(
          color: enabled ? AssistantColors.primary500 : AssistantColors.grayscale200,
        ),
      ),
      icon: Icon(
        icon,
        color: enabled ? AssistantColors.primary500 : AssistantColors.grayscale300,
      ),
      onPressed: enabled ? () => onStep!(step) : null,
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _arrow(
        Icons.chevron_left,
        label('previousPage'),
        -1,
        const Key('assistant-page-previous'),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: AssistantText(
          label('pageOf', {'current': current, 'count': count}),
          textAlign: TextAlign.center,
          style: AssistantTextStyles.h3SemiBold,
          color: AssistantColors.grayscale700,
        ),
      ),
      const SizedBox(width: 8),
      _arrow(
        Icons.chevron_right,
        label('nextPage'),
        1,
        const Key('assistant-page-next'),
      ),
    ],
  );
}

/// A full-width bordered option in the TownPass primary colour.
class _OutlinedChoice extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  /// Shown as a badge so the option can also be chosen by saying its number.
  final int? number;

  /// The badge's screen-reader label, e.g. "第 1 項".
  final String? numberLabel;
  const _OutlinedChoice({
    required this.title,
    this.subtitle = '',
    this.onTap,
    this.number,
    this.numberLabel,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: AssistantColors.white,
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
              color: enabled ? AssistantColors.primary500 : AssistantColors.grayscale200,
            ),
          ),
          child: Row(
            children: [
              if (number != null) ...[
                Semantics(
                  label: numberLabel ?? '$number',
                  child: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: enabled
                          ? AssistantColors.primary500
                          : AssistantColors.grayscale200,
                    ),
                    child: AssistantText(
                      '$number',
                      style: AssistantTextStyles.h3SemiBold,
                      color: AssistantColors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AssistantText(
                      title,
                      style: AssistantTextStyles.h3SemiBold,
                      color: enabled
                          ? AssistantColors.primary700
                          : AssistantColors.grayscale500,
                    ),
                    if (subtitle.isNotEmpty)
                      AssistantText(
                        subtitle,
                        style: AssistantTextStyles.bodyRegular,
                        color: AssistantColors.grayscale600,
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

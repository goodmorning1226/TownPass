import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/assistant/assistant_view_controller.dart';
import 'package:town_pass/util/tp_button.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Root overlay: the original Navigator and native WebView remain the page UI.
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
  final _input = TextEditingController();
  bool _guidanceVisible = true;
  bool _left = false;

  void _refresh(VoidCallback change) {
    change();
    _entry.markNeedsBuild();
  }

  @override
  void didUpdateWidget(covariant AssistantHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    FocusManager.instance.primaryFocus?.unfocus();
    _refresh(() => _guidanceVisible = true);
    widget.controller.submit(value ?? _input.text);
  }

  Widget _buildHost(BuildContext context) {
    final controller = widget.controller;
    final media = MediaQuery.of(context);
    return Stack(
      children: [
        widget.child,
        Obx(() {
          if (controller.hidden.value) return const SizedBox.shrink();
          if (controller.expanded.value) {
            return Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: controller.closePanel,
                      child: const ColoredBox(color: Color(0x33000000)),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: media.viewInsets.bottom + media.padding.bottom + 12,
                    child: Material(
                      color: TPColors.white,
                      elevation: 8,
                      borderRadius: BorderRadius.circular(20),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.max(
                            120,
                            media.size.height -
                                media.viewInsets.bottom -
                                media.padding.top -
                                40,
                          ),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.menu_book_outlined,
                                    color: TPColors.primary700,
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: TPText(
                                      '幫你找服務',
                                      style: TPTextStyles.h3SemiBold,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '關閉助理',
                                    onPressed: controller.closePanel,
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                              const TPText('告訴我想做的事，帶你到原本的服務頁面。'),
                              const SizedBox(height: 16),
                              Semantics(
                                liveRegion: true,
                                child: TPText(controller.message.value),
                              ),
                              for (final choice in controller.choices)
                                TextButton(
                                  onPressed:
                                      controller.busy.value || !choice.enabled
                                      ? null
                                      : () => controller.choose(choice),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          choice.title,
                                          textAlign: TextAlign.start,
                                        ),
                                        if (choice.subtitle.isNotEmpty)
                                          Text(
                                            choice.subtitle,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              color: TPColors.grayscale700,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 16),
                              TextField(
                                key: const Key('assistant-input'),
                                controller: _input,
                                enabled: !controller.busy.value,
                                maxLength: 500,
                                minLines: 1,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  labelText: '想使用什麼服務？',
                                  hintText: '例如：我要借底層邏輯',
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (_) => _submit(),
                              ),
                              const SizedBox(height: 8),
                              if (controller.busy.value)
                                Row(
                                  children: [
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Expanded(child: TPText('正在處理…')),
                                    TextButton(
                                      onPressed: controller.cancel,
                                      child: const Text('取消'),
                                    ),
                                  ],
                                )
                              else
                                TPButton.primary(
                                  text: '幫我找',
                                  onPressed: () => _submit(),
                                ),
                              const SizedBox(height: 10),
                              const TPText(
                                '示範與未串接功能會標示；送出與交易由你確認。',
                                color: TPColors.grayscale700,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
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
                  if (_guidanceVisible && controller.message.value.isNotEmpty)
                    Material(
                      color: TPColors.primary50,
                      elevation: 2,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: 14,
                          top: 8,
                          bottom: 8,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Semantics(
                                liveRegion: true,
                                child: TPText(controller.message.value),
                              ),
                            ),
                            IconButton(
                              tooltip: '收起提示',
                              onPressed: () =>
                                  _refresh(() => _guidanceVisible = false),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onLongPress: () => _refresh(() => _left = !_left),
                    child: FloatingActionButton.extended(
                      heroTag: 'townpass-assistant',
                      tooltip: '開啟助理，長按可移到另一側',
                      backgroundColor: TPColors.primary700,
                      foregroundColor: TPColors.white,
                      onPressed: controller.openPanel,
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('幫我找'),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:townpass_portal_assistant/page/assistant/assistant_texts.dart';
import 'package:townpass_portal_assistant/service/assistant_model_download.dart';
import 'package:townpass_portal_assistant/host/assistant_ui.dart';

String _t(String key, [Map<String, Object> values = const {}]) =>
    AssistantTexts.page(key, values);

/// What went wrong with the last download, or null: a failed request
/// ([AssistantModelDownload.failure]) or the backend's error code.
String? modelDownloadError(AssistantModelDownload downloads) {
  final s = downloads.status.value;
  final failure = downloads.failure.value;
  if (failure != null) return failure;
  if (s == null || s.downloading || s.error == null) return null;
  return switch (s.error) {
    'storage' => _t('modelsErrorStorage', {
      'size': formatModelBytes(_shortBy(downloads, s)),
    }),
    'checksum' => _t('modelsErrorChecksum'),
    'source' => _t('modelsErrorSource'),
    _ => _t('modelsErrorNetwork'),
  };
}

/// 「大約還要 12 分鐘」 for [left]; under a minute 「快下載好了」.
String modelTimeLeftText(Duration left) {
  if (left < const Duration(minutes: 1)) return _t('modelsAlmostDone');
  final minutes = (left.inSeconds / 60).ceil();
  final time = minutes < 60
      ? _t('timeMinutes', {'n': minutes})
      : _t('timeHours', {'h': minutes ~/ 60, 'm': minutes % 60});
  return _t('modelsTimeLeft', {'time': time});
}

/// How much more space the last download needs than the phone has.
int _shortBy(AssistantModelDownload downloads, AssistantModelStatus s) {
  final free = s.freeBytes ?? 0;
  final bytes = downloads.lastBytes;
  final need = bytes + (300 << 20) - free;
  return need > 0 ? need : bytes;
}

/// Shown instead of the conversation while the phone's core models are missing
/// (portal_assistant/docs/AI_CURRENT_RULES.md section 7): what the download is, its size and a
/// 下載 button; nothing downloads before the user taps it. Then its progress,
/// a pause, and what went wrong with a retry.
class ModelDownloadCard extends StatelessWidget {
  final AssistantModelDownload downloads;

  /// 稍後: closes the assistant.
  final VoidCallback? onLater;

  const ModelDownloadCard({super.key, required this.downloads, this.onLater});

  @override
  Widget build(BuildContext context) => Obx(() {
    final s = downloads.status.value;
    final children = <Widget>[
      const Icon(
        Icons.download_for_offline_outlined,
        size: 56,
        color: AssistantColors.primary500,
      ),
      const SizedBox(height: 12),
      AssistantText(
        _t('modelsTitle'),
        style: AssistantTextStyles.h2SemiBold,
        color: AssistantColors.grayscale900,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      ..._body(s),
    ];
    return SingleChildScrollView(
      key: const Key('model-download-card'),
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  });

  List<Widget> _body(AssistantModelStatus? s) {
    // The phone's assistant did not answer yet: ask again, or later
    // (portal_assistant/docs/AI_CURRENT_RULES.md section 7, 2026-11-16).
    if (s == null) {
      return [
        _line(_t('modelsFailed')),
        const SizedBox(height: 20),
        _filled(
          _t('modelsRetry'),
          downloads.busy.value ? null : () => downloads.refreshStatus(),
          key: const Key('model-download-status-retry'),
        ),
        _later(),
      ];
    }
    if (downloads.unavailable) {
      return [_line(_t('modelsUnavailable')), _later()];
    }
    if (s.downloading) {
      final left = downloads.timeLeft;
      return [
        _progress(s),
        if (left != null && !s.retrying)
          KeyedSubtree(
            key: const Key('model-download-time-left'),
            child: _line(modelTimeLeftText(left)),
          ),
        // The network dropped: it tries again by itself for about a minute.
        if (s.retrying) _line(_t('modelsRetrying'), color: AssistantColors.orange700),
        const SizedBox(height: 8),
        // The assistant can be closed meanwhile; the App stays open.
        _line(_t('modelsCanClose')),
        const SizedBox(height: 20),
        _outlined(
          _t('modelsPause'),
          downloads.busy.value ? null : downloads.pause,
          key: const Key('model-download-pause'),
        ),
        _later(),
      ];
    }
    if (!downloads.downloadable('core')) {
      return [_line(_t('modelsErrorSource')), _later()];
    }
    final text = modelDownloadError(downloads);
    if (text != null) {
      return [
        _line(text, color: AssistantColors.red600),
        const SizedBox(height: 20),
        _filled(
          _t('modelsRetry'),
          downloads.busy.value ? null : downloads.retry,
          key: const Key('model-download-retry'),
        ),
        _later(),
      ];
    }
    if (s.state == 'paused') {
      return [
        _progress(s),
        _line(_t('modelsPaused')),
        const SizedBox(height: 20),
        _filled(
          _t('modelsResume'),
          _startOrNull(),
          key: const Key('model-download-resume'),
        ),
        _later(),
      ];
    }
    final tw = s.part('taiwanese');
    final size = formatModelBytes(downloads.offerBytes);
    return [
      _line(_t('modelsBody', {'size': size})),
      const SizedBox(height: 8),
      KeyedSubtree(
        key: const Key('model-download-mobile-data'),
        child: _line(
          _t('modelsMobileData', {'size': size}),
          color: AssistantColors.orange700,
        ),
      ),
      // Lite: no decision model (a lite phone with the decision classifier is not).
      if (s.assistant == 'lite') ...[
        const SizedBox(height: 8),
        _line(_t('modelsLite')),
      ],
      // Off unless chosen: a feature in testing (rules section 7, 2026-11-16).
      if (tw.allowed && !tw.ready)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SwitchListTile(
            key: const Key('model-download-taiwanese'),
            contentPadding: EdgeInsets.zero,
            value: downloads.taiwanese.value,
            activeTrackColor: AssistantColors.primary500,
            onChanged: downloads.chooseTaiwanese,
            title: AssistantText(
              _t('modelsTaiwanese', {
                'size': formatModelBytes(tw.missingBytes),
              }),
              style: AssistantTextStyles.bodyRegular,
              color: AssistantColors.grayscale800,
            ),
            subtitle: AssistantText(
              _t('modelsTaiwaneseNote'),
              style: AssistantTextStyles.caption,
              color: AssistantColors.grayscale700,
            ),
          ),
        ),
      const SizedBox(height: 20),
      _filled(
        _t('modelsDownload'),
        _startOrNull(),
        key: const Key('model-download-start'),
      ),
      _later(),
    ];
  }

  VoidCallback? _startOrNull() =>
      downloads.busy.value ? null : () => downloads.start();

  Widget _progress(AssistantModelStatus s) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: s.total > 0 ? s.done / s.total : null,
          minHeight: 10,
          color: AssistantColors.primary500,
          backgroundColor: AssistantColors.grayscale200,
        ),
      ),
      const SizedBox(height: 8),
      _line(
        _t('modelsProgress', {
          'done': formatModelBytes(s.done),
          'total': formatModelBytes(s.total),
          'percent': s.percent,
        }),
      ),
    ],
  );

  Widget _line(String text, {Color color = AssistantColors.grayscale700}) => AssistantText(
    text,
    style: AssistantTextStyles.bodyRegular,
    color: color,
    textAlign: TextAlign.center,
  );

  Widget _later() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextButton(
      key: const Key('model-download-later'),
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: onLater,
      child: AssistantText(
        _t('modelsLater'),
        style: AssistantTextStyles.h3Regular,
        color: AssistantColors.grayscale700,
      ),
    ),
  );
}

Widget _filled(String label, VoidCallback? onPressed, {Key? key}) => SizedBox(
  height: 48,
  child: ElevatedButton(
    key: key,
    style: ElevatedButton.styleFrom(
      backgroundColor: AssistantColors.primary500,
      foregroundColor: AssistantColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    onPressed: onPressed,
    child: Text(
      label,
      style: AssistantTextStyles.h3SemiBold.copyWith(color: AssistantColors.white),
    ),
  ),
);

Widget _outlined(String label, VoidCallback? onPressed, {Key? key}) => SizedBox(
  height: 48,
  child: OutlinedButton(
    key: key,
    style: OutlinedButton.styleFrom(
      backgroundColor: AssistantColors.white,
      side: const BorderSide(color: AssistantColors.primary500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    onPressed: onPressed,
    child: Text(
      label,
      style: AssistantTextStyles.h3Regular.copyWith(color: AssistantColors.primary700),
    ),
  ),
);

/// Above the conversation while the decision model is still to come: the
/// assistant works, but lists options instead of choosing (rules section 7).
class ModelDownloadBanner extends StatelessWidget {
  final AssistantModelDownload downloads;

  const ModelDownloadBanner({super.key, required this.downloads});

  @override
  Widget build(BuildContext context) => Obx(() {
    final s = downloads.status.value;
    if (s == null || !downloads.decisionPending) return const SizedBox.shrink();
    return Container(
      key: const Key('model-download-banner'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AssistantColors.primary50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: AssistantText(
              _t('modelsDecisionPending', {'percent': s.percent}),
              style: AssistantTextStyles.caption,
              color: AssistantColors.grayscale800,
            ),
          ),
          if (!s.downloading && downloads.downloadable('decision'))
            TextButton(
              onPressed: downloads.busy.value
                  ? null
                  : () => downloads.start(const ['decision']),
              child: AssistantText(
                _t('modelsResume'),
                style: AssistantTextStyles.caption,
                color: AssistantColors.primary700,
              ),
            ),
        ],
      ),
    );
  });
}

/// AI 助理設定 > 離線模型: what is on the phone, the optional Taiwanese model,
/// resuming, pausing and retrying a download, and deleting the models.
class ModelDownloadSettings extends StatefulWidget {
  final AssistantModelDownload downloads;

  const ModelDownloadSettings({super.key, required this.downloads});

  @override
  State<ModelDownloadSettings> createState() => _ModelDownloadSettingsState();
}

class _ModelDownloadSettingsState extends State<ModelDownloadSettings> {
  AssistantModelDownload get downloads => widget.downloads;

  @override
  void initState() {
    super.initState();
    // What is on the phone now: a download may have stopped (or a file gone)
    // since the status was last asked (2026-11-13).
    unawaited(downloads.refreshStatus());
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final s = downloads.status.value;
    if (s == null || !downloads.managed) return const SizedBox.shrink();
    final parts = [
      for (final p in const ['core', 'decision', 'taiwanese']) s.part(p),
    ].where((p) => p.allowed);
    final have = parts.fold(0, (sum, p) => sum + p.bytes - p.missingBytes);
    final core = s.part('core');
    final decision = s.part('decision');
    final tw = s.part('taiwanese');
    final missingRequired =
        (!core.ready && core.allowed) || (!decision.ready && decision.allowed);
    final error = modelDownloadError(downloads);
    return Padding(
      key: const Key('model-download-settings'),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AssistantText(
            _t('modelsSettingsHeader'),
            style: AssistantTextStyles.h3SemiBold,
            color: AssistantColors.grayscale900,
          ),
          const SizedBox(height: 6),
          // One line per part with its size: 「已下載 643 MB，還有 0 MB 未下載」
          // was hard to read (rules section 7, 2026-11-16).
          for (final (name, key) in const [
            ('core', 'modelsCore'),
            ('decision', 'modelsDecision'),
            ('taiwanese', 'modelsTaiwanesePart'),
          ])
            if (s.part(name).allowed)
              Padding(
                key: Key('model-download-settings-$name'),
                padding: const EdgeInsets.only(bottom: 2),
                child: AssistantText(
                  _t('modelsPartLine', {
                    'part': _t(key),
                    'state': _partState(s.part(name)),
                  }),
                  style: AssistantTextStyles.bodyRegular,
                  color: AssistantColors.grayscale700,
                ),
              ),
          if (s.downloading) ...[
            const SizedBox(height: 8),
            AssistantText(
              _t('modelsProgress', {
                'done': formatModelBytes(s.done),
                'total': formatModelBytes(s.total),
                'percent': s.percent,
              }),
              style: AssistantTextStyles.bodyRegular,
              color: AssistantColors.grayscale700,
            ),
            if (s.retrying)
              KeyedSubtree(
                key: const Key('model-download-settings-retrying'),
                child: AssistantText(
                  _t('modelsRetrying'),
                  style: AssistantTextStyles.bodyRegular,
                  color: AssistantColors.orange700,
                ),
              ),
            const SizedBox(height: 8),
            // The download (Taiwanese, too) can be paused here: what arrived stays.
            _outlined(
              _t('modelsPause'),
              downloads.busy.value ? null : downloads.pause,
              key: const Key('model-download-settings-pause'),
            ),
          ] else if (error != null) ...[
            // A failed download (e.g. the optional Taiwanese one) says why, with a
            // retry of the same parts (rules section 7, 2026-11-13).
            const SizedBox(height: 8),
            KeyedSubtree(
              key: const Key('model-download-settings-error'),
              child: AssistantText(
                error,
                style: AssistantTextStyles.bodyRegular,
                color: AssistantColors.red600,
              ),
            ),
            if (s.error != 'source') ...[
              const SizedBox(height: 8),
              _filled(
                _t('modelsRetry'),
                downloads.busy.value ? null : downloads.retry,
                key: const Key('model-download-settings-retry'),
              ),
            ],
          ] else if (s.state == 'paused') ...[
            const SizedBox(height: 8),
            KeyedSubtree(
              key: const Key('model-download-settings-paused'),
              child: AssistantText(
                _t('modelsPaused'),
                style: AssistantTextStyles.bodyRegular,
                color: AssistantColors.grayscale700,
              ),
            ),
          ],
          const SizedBox(height: 12),
          // After a failure the retry above takes the place of these.
          if (missingRequired &&
              !s.downloading &&
              error == null &&
              downloads.downloadable('core'))
            _filled(
              _t('modelsResume'),
              downloads.busy.value ? null : () => downloads.start(),
            ),
          if (tw.allowed &&
              !tw.ready &&
              !s.downloading &&
              error == null &&
              downloads.downloadable('taiwanese')) ...[
            const SizedBox(height: 8),
            _outlined(
              _t('modelsTaiwaneseAdd', {
                'size': formatModelBytes(tw.missingBytes),
              }),
              downloads.busy.value
                  ? null
                  : () => downloads.start(const ['taiwanese']),
              key: const Key('model-download-taiwanese-add'),
            ),
          ],
          // Taiwanese alone (a feature in testing; 0.8 GB).
          if (tw.ready && !s.downloading) ...[
            const SizedBox(height: 8),
            _deleteButton(
              _t('modelsTaiwaneseDelete'),
              () => _confirmDelete(
                context,
                _t('modelsTaiwaneseDeleteConfirm'),
                _t('modelsTaiwaneseDelete'),
                downloads.deleteTaiwanese,
              ),
              key: const Key('model-download-delete-taiwanese'),
            ),
          ],
          if (have > 0) ...[
            const SizedBox(height: 4),
            _deleteButton(
              _t('modelsDelete'),
              () => _confirmDelete(
                context,
                _t('modelsDeleteConfirm'),
                _t('modelsDelete'),
                downloads.delete,
              ),
              key: const Key('model-download-delete'),
            ),
          ],
        ],
      ),
    );
  });

  /// 「已下載（512 MB）」, 「未下載（848 MB）」 or 「還要下載 20 MB（共 132 MB）」.
  static String _partState(AssistantModelPart p) {
    final size = formatModelBytes(p.bytes);
    if (p.ready || p.missingBytes == 0) {
      return _t('modelsPartReady', {'size': size});
    }
    if (p.missingBytes >= p.bytes) return _t('modelsPartNone', {'size': size});
    return _t('modelsPartMissing', {
      'missing': formatModelBytes(p.missingBytes),
      'size': size,
    });
  }

  Widget _deleteButton(String label, VoidCallback onTap, {Key? key}) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      key: key,
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: downloads.busy.value ? null : onTap,
      child: AssistantText(
        label,
        style: AssistantTextStyles.bodyRegular,
        color: AssistantColors.red600,
      ),
    ),
  );

  Future<void> _confirmDelete(
    BuildContext context,
    String question,
    String yesLabel,
    Future<void> Function() delete,
  ) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(yesLabel),
          ),
        ],
      ),
    );
    if (yes == true) await delete();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/assistant/assistant_texts.dart';
import 'package:town_pass/service/assistant_model_download.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

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

/// How much more space the last download needs than the phone has.
int _shortBy(AssistantModelDownload downloads, AssistantModelStatus s) {
  final free = s.freeBytes ?? 0;
  final bytes = downloads.lastBytes;
  final need = bytes + (300 << 20) - free;
  return need > 0 ? need : bytes;
}

/// Shown instead of the conversation while the phone's core models are missing
/// (docs/AI_CURRENT_RULES.md section 7): what the download is, its size and a
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
        color: TPColors.primary500,
      ),
      const SizedBox(height: 12),
      TPText(
        _t('modelsTitle'),
        style: TPTextStyles.h2SemiBold,
        color: TPColors.grayscale900,
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
    if (s == null) return [_line(_t('modelsFailed'))];
    if (downloads.unavailable) {
      return [_line(_t('modelsUnavailable')), _later()];
    }
    if (s.downloading) {
      return [
        _progress(s),
        // The network dropped: it tries again by itself for about a minute.
        if (s.retrying) _line(_t('modelsRetrying'), color: TPColors.orange700),
        const SizedBox(height: 20),
        _outlined(
          _t('modelsPause'),
          downloads.busy.value ? null : downloads.pause,
          key: const Key('model-download-pause'),
        ),
      ];
    }
    if (!downloads.downloadable('core')) {
      return [_line(_t('modelsErrorSource')), _later()];
    }
    final text = modelDownloadError(downloads);
    if (text != null) {
      return [
        _line(text, color: TPColors.red600),
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
    return [
      _line(_t('modelsBody', {'size': formatModelBytes(downloads.offerBytes)})),
      // Lite: no decision model (a lite phone with the decision classifier is not).
      if (s.assistant == 'lite') ...[
        const SizedBox(height: 8),
        _line(_t('modelsLite')),
      ],
      if (tw.allowed && !tw.ready)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SwitchListTile(
            key: const Key('model-download-taiwanese'),
            contentPadding: EdgeInsets.zero,
            value: downloads.taiwanese.value,
            activeTrackColor: TPColors.primary500,
            onChanged: downloads.chooseTaiwanese,
            title: TPText(
              _t('modelsTaiwanese', {
                'size': formatModelBytes(tw.missingBytes),
              }),
              style: TPTextStyles.bodyRegular,
              color: TPColors.grayscale800,
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
          color: TPColors.primary500,
          backgroundColor: TPColors.grayscale200,
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

  Widget _line(String text, {Color color = TPColors.grayscale700}) => TPText(
    text,
    style: TPTextStyles.bodyRegular,
    color: color,
    textAlign: TextAlign.center,
  );

  Widget _later() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextButton(
      key: const Key('model-download-later'),
      onPressed: onLater,
      child: TPText(
        _t('modelsLater'),
        style: TPTextStyles.h3Regular,
        color: TPColors.grayscale700,
      ),
    ),
  );
}

Widget _filled(String label, VoidCallback? onPressed, {Key? key}) => SizedBox(
  height: 48,
  child: ElevatedButton(
    key: key,
    style: ElevatedButton.styleFrom(
      backgroundColor: TPColors.primary500,
      foregroundColor: TPColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    onPressed: onPressed,
    child: Text(
      label,
      style: TPTextStyles.h3SemiBold.copyWith(color: TPColors.white),
    ),
  ),
);

Widget _outlined(String label, VoidCallback? onPressed, {Key? key}) => SizedBox(
  height: 48,
  child: OutlinedButton(
    key: key,
    style: OutlinedButton.styleFrom(
      backgroundColor: TPColors.white,
      side: const BorderSide(color: TPColors.primary500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    onPressed: onPressed,
    child: Text(
      label,
      style: TPTextStyles.h3Regular.copyWith(color: TPColors.primary700),
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
        color: TPColors.primary50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: TPText(
              _t('modelsDecisionPending', {'percent': s.percent}),
              style: TPTextStyles.caption,
              color: TPColors.grayscale800,
            ),
          ),
          if (!s.downloading && downloads.downloadable('decision'))
            TextButton(
              onPressed: downloads.busy.value
                  ? null
                  : () => downloads.start(const ['decision']),
              child: TPText(
                _t('modelsResume'),
                style: TPTextStyles.caption,
                color: TPColors.primary700,
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
          TPText(
            _t('modelsSettingsHeader'),
            style: TPTextStyles.h3SemiBold,
            color: TPColors.grayscale900,
          ),
          const SizedBox(height: 6),
          TPText(
            _t('modelsSettingsState', {
              'have': formatModelBytes(have),
              'missing': formatModelBytes(
                (core.allowed ? core.missingBytes : 0) +
                    (decision.allowed ? decision.missingBytes : 0),
              ),
            }),
            style: TPTextStyles.bodyRegular,
            color: TPColors.grayscale700,
          ),
          if (s.downloading) ...[
            const SizedBox(height: 8),
            TPText(
              _t('modelsProgress', {
                'done': formatModelBytes(s.done),
                'total': formatModelBytes(s.total),
                'percent': s.percent,
              }),
              style: TPTextStyles.bodyRegular,
              color: TPColors.grayscale700,
            ),
            if (s.retrying)
              KeyedSubtree(
                key: const Key('model-download-settings-retrying'),
                child: TPText(
                  _t('modelsRetrying'),
                  style: TPTextStyles.bodyRegular,
                  color: TPColors.orange700,
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
              child: TPText(
                error,
                style: TPTextStyles.bodyRegular,
                color: TPColors.red600,
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
              child: TPText(
                _t('modelsPaused'),
                style: TPTextStyles.bodyRegular,
                color: TPColors.grayscale700,
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
          if (have > 0) ...[
            const SizedBox(height: 8),
            TextButton(
              key: const Key('model-download-delete'),
              onPressed: downloads.busy.value
                  ? null
                  : () => _confirmDelete(context),
              child: TPText(
                _t('modelsDelete'),
                style: TPTextStyles.bodyRegular,
                color: TPColors.red600,
              ),
            ),
          ],
        ],
      ),
    );
  });

  Future<void> _confirmDelete(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(_t('modelsDeleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_t('modelsDelete')),
          ),
        ],
      ),
    );
    if (yes == true) await downloads.delete();
  }
}

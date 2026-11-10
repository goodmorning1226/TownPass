import 'dart:async';

import 'package:get/get.dart';
import 'package:town_pass/service/assistant_service.dart';

/// One part of the phone's models (assistant_backend/models.py PARTS).
class AssistantModelPart {
  final bool allowed;
  final bool ready;
  final bool downloadable;
  final int bytes;
  final int missingBytes;

  const AssistantModelPart({
    this.allowed = false,
    this.ready = false,
    this.downloadable = false,
    this.bytes = 0,
    this.missingBytes = 0,
  });

  static AssistantModelPart parse(Object? json) {
    if (json is! Map) return const AssistantModelPart();
    int number(Object? value) => value is int && value >= 0 ? value : 0;
    return AssistantModelPart(
      allowed: json['allowed'] == true,
      ready: json['ready'] == true,
      downloadable: json['downloadable'] == true,
      bytes: number(json['bytes']),
      missingBytes: number(json['missing_bytes']),
    );
  }
}

/// GET /v1/models (docs/AI_MODEL_DOWNLOAD.md).
class AssistantModelStatus {
  /// False on the computer backend: nothing is downloaded by the App.
  final bool managed;

  /// "full", "standard" or "lite" (the phone's total memory).
  final String tier;

  /// "full", "lite" (no decision model) or "unavailable".
  final String assistant;
  final int? freeBytes;
  final Map<String, AssistantModelPart> parts;

  /// "idle", "downloading", "paused", "error" or "done".
  final String state;

  /// "network", "storage", "checksum" or "source" after a failed download.
  final String? error;
  final int done;
  final int total;

  const AssistantModelStatus({
    this.managed = false,
    this.tier = 'full',
    this.assistant = 'full',
    this.freeBytes,
    this.parts = const {},
    this.state = 'idle',
    this.error,
    this.done = 0,
    this.total = 0,
  });

  factory AssistantModelStatus.fromJson(Map<String, dynamic> json) {
    if (json['managed'] != true) return const AssistantModelStatus();
    final parts = json['parts'];
    final progress = json['progress'];
    String text(Object? value, String fallback) =>
        value is String && value.length <= 16 ? value : fallback;
    int number(Object? value) => value is int && value >= 0 ? value : 0;
    return AssistantModelStatus(
      managed: true,
      tier: text(json['tier'], 'full'),
      assistant: text(json['assistant'], 'full'),
      freeBytes: json['free_bytes'] is int ? json['free_bytes'] as int : null,
      parts: {
        for (final name in const ['core', 'decision', 'taiwanese'])
          name: AssistantModelPart.parse(parts is Map ? parts[name] : null),
      },
      state: text(json['state'], 'idle'),
      error: json['error'] is String ? json['error'] as String : null,
      done: progress is Map ? number(progress['done']) : 0,
      total: progress is Map ? number(progress['total']) : 0,
    );
  }

  AssistantModelPart part(String name) =>
      parts[name] ?? const AssistantModelPart();

  bool get downloading => state == 'downloading';

  int get percent => total <= 0 ? 0 : (done * 100 ~/ total).clamp(0, 100);
}

/// The phone's model downloads for both assistant UIs (rules section 7): the
/// first time the assistant opens without its core models, it offers the
/// download (size, Wi-Fi advice, Taiwanese as an option) and starts it only
/// when the user taps 下載; progress is polled while it runs. Registered only in
/// on-device builds (main.dart); [maybe] is null elsewhere.
class AssistantModelDownload extends GetxService {
  /// A mirror for every file (the city's server, or a test server reached
  /// through adb reverse); empty: each file's own source.
  static const mirror = String.fromEnvironment('ASSISTANT_MODEL_BASE_URL');

  final AssistantService service;
  final Duration poll;

  /// Null until the backend has answered once.
  final status = Rxn<AssistantModelStatus>();

  /// A start, pause or delete request is on its way.
  final busy = false.obs;

  /// The user's choice for Taiwanese on the offer (default on full phones).
  final taiwanese = false.obs;
  bool _taiwaneseChosen = false;

  /// The last request failed (texts key), shown with a retry.
  final failure = RxnString();

  Timer? _timer;

  AssistantModelDownload({
    AssistantService? service,
    this.poll = const Duration(seconds: 1),
  }) : service = service ?? AssistantService();

  static AssistantModelDownload? get maybe =>
      Get.isRegistered<AssistantModelDownload>()
      ? Get.find<AssistantModelDownload>()
      : null;

  @override
  void onInit() {
    super.onInit();
    unawaited(_firstStatus());
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }

  /// The backend starts with the App and may need a few seconds.
  Future<void> _firstStatus() async {
    for (var attempt = 0; attempt < 40 && status.value == null; attempt++) {
      await refreshStatus();
      if (status.value != null || isClosed) return;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> refreshStatus() async {
    try {
      _apply(await service.modelStatus());
    } on FormatException {
      // Not reachable yet: the assistant says so itself; asked again later.
    }
  }

  void _apply(Map<String, dynamic> json) {
    final next = AssistantModelStatus.fromJson(json);
    status.value = next;
    if (!_taiwaneseChosen) {
      taiwanese.value = next.tier == 'full' && next.part('taiwanese').allowed;
    }
    if (next.downloading) {
      _timer ??= Timer.periodic(poll, (_) => refreshStatus());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  AssistantModelStatus? get _s => status.value;

  /// The phone manages its own models (on-device builds).
  bool get managed => _s?.managed ?? false;

  /// The assistant cannot work yet: its core models are missing. Both UIs show
  /// the download instead of the conversation.
  bool get needsCore => managed && !_s!.part('core').ready || unavailable;

  /// This phone cannot run the assistant at all.
  bool get unavailable => managed && _s!.assistant == 'unavailable';

  /// Usable, but the decision model is still to come: a banner says so.
  bool get decisionPending =>
      managed &&
      _s!.part('core').ready &&
      _s!.part('decision').allowed &&
      !_s!.part('decision').ready;

  /// The files can be fetched (a source in the manifest, or a mirror).
  bool downloadable(String part) =>
      mirror.isNotEmpty || (_s?.part(part).downloadable ?? false);

  void chooseTaiwanese(bool value) {
    _taiwaneseChosen = true;
    taiwanese.value = value;
  }

  /// What the offer downloads: the core, then the decision model, and
  /// Taiwanese when chosen.
  List<String> get offerParts {
    final s = _s;
    if (s == null) return const [];
    return [
      if (s.part('core').allowed && !s.part('core').ready) 'core',
      if (s.part('decision').allowed && !s.part('decision').ready) 'decision',
      if (taiwanese.value &&
          s.part('taiwanese').allowed &&
          !s.part('taiwanese').ready)
        'taiwanese',
    ];
  }

  int get offerBytes {
    final s = _s;
    if (s == null) return 0;
    return offerParts.fold(0, (sum, p) => sum + s.part(p).missingBytes);
  }

  Future<void> start([List<String>? parts]) => _act(
    () => service.downloadModels(
      parts ?? offerParts,
      baseUrl: mirror.isEmpty ? null : mirror,
    ),
  );

  Future<void> pause() => _act(service.pauseModelDownload);

  Future<void> delete([
    List<String> parts = const ['core', 'decision', 'taiwanese'],
  ]) => _act(() => service.deleteModels(parts));

  Future<void> _act(Future<Map<String, dynamic>> Function() request) async {
    if (busy.value) return;
    busy.value = true;
    failure.value = null;
    try {
      _apply(await request());
    } on FormatException catch (error) {
      failure.value = error.message;
    } finally {
      busy.value = false;
    }
  }
}

/// "2.9 GB", "450 MB".
String formatModelBytes(int bytes) {
  const mb = 1024 * 1024;
  if (bytes >= 1000 * mb) {
    return '${(bytes / (1024 * mb)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / mb).ceil()} MB';
}

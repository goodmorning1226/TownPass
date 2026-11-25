import 'dart:async';

import 'package:get/get.dart';
import 'package:townpass_portal_assistant/service/assistant_service.dart';

/// One part of the phone's models (portal_assistant/backend/models.py PARTS).
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

/// GET /v1/models (portal_assistant/docs/AI_MODEL_DOWNLOAD.md).
class AssistantModelStatus {
  /// False on the computer backend: nothing is downloaded by the App.
  final bool managed;

  /// "full", "standard" or "lite" (the phone's total memory).
  final String tier;

  /// "full", "lite" (no decision model) or "unavailable". A lite-tier phone
  /// with the decision classifier (ASSISTANT_DECISION_MODEL=classifier, 132 MB
  /// on every tier) is "full": its decision part is allowed.
  final String assistant;
  final int? freeBytes;
  final Map<String, AssistantModelPart> parts;

  /// "idle", "downloading", "paused", "error" or "done".
  final String state;

  /// "network", "storage", "checksum" or "source" after a failed download.
  final String? error;

  /// The network dropped and the download waits to try again by itself
  /// (models.py: about a minute before it stops with "network").
  final bool retrying;
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
    this.retrying = false,
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
      retrying: json['retrying'] == true,
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

  /// The user's choice for Taiwanese on the offer. Off until chosen: it is a
  /// feature in testing and another 0.8 GB (portal_assistant/docs/AI_CURRENT_RULES.md section 7,
  /// 2026-11-16; it was on by default on full phones).
  final taiwanese = false.obs;

  /// The last request failed (texts key), shown with a retry.
  final failure = RxnString();

  /// Counts the times the core models became ready while the App was open
  /// (from missing to ready): the assistant says the download is done.
  final coreReady = 0.obs;

  /// The clock for the time-left estimate (tests replace it).
  final DateTime Function() now;

  Timer? _timer;

  AssistantModelDownload({
    AssistantService? service,
    this.poll = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : service = service ?? AssistantService(),
       now = now ?? DateTime.now;

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
    final before = status.value;
    _sample(next);
    status.value = next;
    if (before != null &&
        before.managed &&
        !before.part('core').ready &&
        next.part('core').ready) {
      coreReady.value++;
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

  void chooseTaiwanese(bool value) => taiwanese.value = value;

  /// Recent (time, bytes done) while downloading, for [timeLeft].
  final _samples = <(DateTime, int)>[];

  /// How far back the speed is measured.
  static const speedWindow = Duration(seconds: 20);

  void _sample(AssistantModelStatus next) {
    if (!next.downloading) {
      _samples.clear();
      return;
    }
    final at = now();
    // A new plan (or a part started over): measure afresh.
    if (_samples.isNotEmpty && next.done < _samples.last.$2) _samples.clear();
    _samples.add((at, next.done));
    _samples.removeWhere((sample) => at.difference(sample.$1) > speedWindow);
  }

  /// About how long the running download still takes, from the speed of the
  /// last [speedWindow]; null while it is not known yet (under 3 s measured,
  /// or nothing arrived) or when nothing downloads.
  Duration? get timeLeft {
    final s = _s;
    if (s == null || !s.downloading || _samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final seconds = last.$1.difference(first.$1).inMilliseconds / 1000;
    final bytes = last.$2 - first.$2;
    if (seconds < 3 || bytes <= 0) return null;
    final left = (s.total - s.done).clamp(0, s.total);
    return Duration(seconds: (left / (bytes / seconds)).ceil());
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

  /// The parts of the last download asked for (null: none yet this launch),
  /// so that 再試一次 retries what failed, e.g. only Taiwanese from Settings.
  List<String>? lastParts;

  Future<void> start([List<String>? parts]) {
    final asked = parts ?? offerParts;
    lastParts = asked;
    return _act(
      () => service.downloadModels(
        asked,
        baseUrl: mirror.isEmpty ? null : mirror,
      ),
    );
  }

  /// 再試一次 after a failed download: the same parts again (each file
  /// resumes from what arrived), or the offer when nothing was asked yet.
  Future<void> retry() => start(lastParts);

  /// What the last download asked for and still misses, in bytes.
  int get lastBytes {
    final s = _s;
    final parts = lastParts;
    if (s == null || parts == null) return offerBytes;
    return parts.fold(0, (sum, p) => sum + s.part(p).missingBytes);
  }

  Future<void> pause() => _act(service.pauseModelDownload);

  Future<void> delete([
    List<String> parts = const ['core', 'decision', 'taiwanese'],
  ]) => _act(() => service.deleteModels(parts));

  /// AI 助理設定: Taiwanese alone; the core and decision models stay.
  Future<void> deleteTaiwanese() => delete(const ['taiwanese']);

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

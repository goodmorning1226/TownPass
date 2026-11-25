import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Hold-to-talk capture for the assistant: mono PCM16 kept in memory and
/// wrapped as a 16 kHz WAV. Audio is never written to a file.
///
/// Capture runs at 48 kHz, the native rate of Android audio hardware, and is
/// downsampled here. Asking the platform for 16 kHz directly produced audio
/// stretched about three times on the Android emulator (48 kHz data labelled
/// 16 kHz), which made speech unrecognisable.
///
/// Each recording uses a fresh platform recorder (reusing one across
/// sessions risked the next session delivering silence). The next one is
/// made ahead with [prepare], so a press only has to start the stream
/// (portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-18): preparing creates the
/// object and checks the permission without asking; it never opens the
/// microphone.
class AssistantRecorder {
  static const sampleRate = 16000;
  static const captureRate = 48000;
  static const _factor = captureRate ~/ sampleRate;
  static const maxDuration = Duration(seconds: 30);
  static const _maxBytes = captureRate * 2 * 30;

  /// [create] makes the platform recorder (tests pass a fake).
  AssistantRecorder({AudioRecorder Function()? create})
    : _create = create ?? AudioRecorder.new;

  final AudioRecorder Function() _create;

  /// Called with each chunk's loudness (RMS, 0-1) while recording. The first
  /// call of a recording is the microphone really listening.
  void Function(double level)? onLevel;

  /// How long the microphone takes to start, from the press (debug log).
  final timing = MicTiming();

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  BytesBuilder? _pcm;
  Completer<void>? _done;

  /// The next recording's recorder, made ahead ([prepare]), and whether the
  /// microphone was allowed when it was made (null: not known).
  AudioRecorder? _next;
  Future<bool?>? _nextAllowed;

  /// [prepare] was asked and not [release]d: a used recorder is replaced by
  /// a prepared one right away.
  bool _keepReady = false;

  /// Whether a recorder is prepared now (tests).
  @visibleForTesting
  bool get prepared => _next != null;

  /// The iOS audio session's category is set once per launch.
  static bool _sessionSet = false;

  /// Makes the next recording's platform recorder now and checks the
  /// permission without asking, so the press only starts the stream. Never
  /// starts recording: the microphone stays closed until [start]. Keeps one
  /// ready after each recording until [release].
  Future<void> prepare() {
    _keepReady = true;
    return _prepareNext();
  }

  /// Drops the prepared recorder (no microphone on screen, or the App went
  /// to the background); the next [start] makes its own.
  Future<void> release() async {
    _keepReady = false;
    final next = _next;
    _next = null;
    _nextAllowed = null;
    if (next == null) return;
    try {
      await next.dispose();
    } catch (_) {}
  }

  Future<void> _prepareNext() async {
    if (_next != null) return;
    final next = _next = _create();
    final allowed = _nextAllowed = _check(next);
    await allowed;
  }

  Future<bool?> _check(AudioRecorder recorder) async {
    try {
      final allowed = await recorder.hasPermission(request: false);
      if (allowed) await _setSession(recorder);
      return allowed;
    } catch (_) {
      return null;
    }
  }

  /// iOS: puts the audio session in the category recording uses (the same
  /// as `startStream`'s own: play and record, speaker, Bluetooth), so the
  /// press does not switch it. The session is not activated: that would stop
  /// other apps' audio while nothing is recorded.
  static Future<void> _setSession(AudioRecorder recorder) async {
    if (_sessionSet) return;
    final ios = recorder.ios;
    if (ios == null) return;
    _sessionSet = true;
    try {
      await ios.setAudioSessionCategory(
        category: IosAudioCategory.playAndRecord,
        options: const [
          IosAudioCategoryOptions.defaultToSpeaker,
          IosAudioCategoryOptions.allowBluetooth,
          IosAudioCategoryOptions.allowBluetoothA2DP,
        ],
      );
    } catch (_) {}
  }

  /// Whether the microphone may be used already, without asking (so the
  /// assistant can explain why before the system's permission prompt;
  /// portal_assistant/docs/AI_CURRENT_RULES.md section 5). True when it cannot be told.
  Future<bool> micAllowed() async {
    AudioRecorder? probe;
    try {
      probe = _create();
      return await probe.hasPermission(request: false);
    } catch (_) {
      return true;
    } finally {
      try {
        await probe?.dispose();
      } catch (_) {}
    }
  }

  /// Shows the system's microphone permission prompt now, without recording
  /// (right after the assistant has explained why; portal_assistant/docs/AI_CURRENT_RULES.md
  /// section 5). True when allowed.
  Future<bool> requestMic() async {
    AudioRecorder? probe;
    try {
      probe = _create();
      return await probe.hasPermission();
    } catch (_) {
      return false;
    } finally {
      try {
        await probe?.dispose();
      } catch (_) {}
    }
  }

  /// True while [start] waits for the system's permission prompt, and after
  /// a [start] that did not get the permission: releasing the button then is
  /// not "too quick" (portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-16).
  bool permissionPending = false;

  /// The [start] running now: a second press waits for it, so two starts
  /// never share (or orphan) a recorder.
  Future<void>? _starting;

  /// Starts capturing; false when the microphone permission is not granted.
  /// The microphone is listening once the first [onLevel] arrives.
  Future<bool> start() async {
    final previous = _starting;
    final gate = Completer<void>();
    _starting = gate.future;
    try {
      if (previous != null) await previous;
      return await _start();
    } finally {
      gate.complete();
      if (identical(_starting, gate.future)) _starting = null;
    }
  }

  Future<bool> _start() async {
    permissionPending = false;
    await _discard();
    // Taken before waiting, so a [release] meanwhile cannot dispose it.
    final next = _next;
    final allowed = _nextAllowed;
    _next = null;
    _nextAllowed = null;
    final known = await allowed;
    timing.begin(prepared: next != null && known == true);
    final recorder = _recorder = next ?? _create();
    if (known != true && !await recorder.hasPermission(request: false)) {
      // Not allowed yet: the system asks now (or refuses at once).
      permissionPending = true;
      if (!await recorder.hasPermission()) return false;
      permissionPending = false;
    }
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: captureRate,
        numChannels: 1,
      ),
    );
    timing.started();
    if (!identical(recorder, _recorder)) {
      // Stopped or cancelled while the stream started: that already stopped
      // and threw away this recorder.
      return true;
    }
    final pcm = _pcm = BytesBuilder(copy: false);
    final done = _done = Completer<void>();
    _subscription = stream.listen(
      (chunk) {
        if (pcm.length < _maxBytes) pcm.add(chunk);
        final level = rms(chunk);
        timing.chunk(level);
        onLevel?.call(level);
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (_) => done.isCompleted ? null : done.complete(),
    );
    return true;
  }

  /// Stops and returns the recording as WAV, or null when nothing was captured.
  /// The used recorder is discarded and the next one prepared.
  Future<Uint8List?> stop() async {
    timing.report('stop');
    final pcm = _pcm;
    final done = _done;
    final recorder = _recorder;
    _pcm = null;
    _done = null;
    if (pcm == null) {
      await _discard();
      return null;
    }
    _recorder = null;
    try {
      await recorder?.stop();
    } catch (_) {}
    // Let the final buffered chunk arrive before closing the stream.
    await done?.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    await _subscription?.cancel();
    _subscription = null;
    if (recorder != null) await _drop(recorder);
    return pcm.isEmpty ? null : wav(downsample(pcm.takeBytes()));
  }

  /// Discards the current recording; the next recorder is prepared.
  Future<void> cancel() async {
    timing.report('cancel');
    await _discard();
  }

  Future<void> dispose() async {
    timing.report('dispose');
    _keepReady = false;
    await _discard();
    await release();
  }

  /// Ends the current capture, if any, and throws its recorder away.
  Future<void> _discard() async {
    _pcm = null;
    _done = null;
    await _subscription?.cancel();
    _subscription = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) await _drop(recorder);
  }

  /// A used (or stale) recorder is never used again; with [prepare] asked,
  /// the next one is made right away.
  Future<void> _drop(AudioRecorder recorder) async {
    try {
      if (await recorder.isRecording()) await recorder.cancel();
    } catch (_) {}
    try {
      await recorder.dispose();
    } catch (_) {}
    if (_keepReady) unawaited(_prepareNext());
  }

  /// Wraps little-endian PCM16 mono samples in a 44-byte RIFF/WAVE header.
  static Uint8List wav(Uint8List pcm, {int rate = sampleRate}) {
    final header = ByteData(44)
      ..setUint32(0, 0x52494646) // "RIFF"
      ..setUint32(4, 36 + pcm.length, Endian.little)
      ..setUint32(8, 0x57415645) // "WAVE"
      ..setUint32(12, 0x666d7420) // "fmt "
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, 1, Endian.little) // mono
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461) // "data"
      ..setUint32(40, pcm.length, Endian.little);
    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(pcm))
        .takeBytes();
  }

  /// 48 kHz -> 16 kHz PCM16: averages each group of three samples, a simple
  /// low-pass that is adequate for speech recognition.
  static Uint8List downsample(Uint8List pcm) {
    final input = ByteData.sublistView(pcm);
    final frames = pcm.length ~/ (2 * _factor);
    final output = ByteData(frames * 2);
    for (var i = 0; i < frames; i++) {
      var sum = 0;
      for (var j = 0; j < _factor; j++) {
        sum += input.getInt16((i * _factor + j) * 2, Endian.little);
      }
      output.setInt16(i * 2, sum ~/ _factor, Endian.little);
    }
    return output.buffer.asUint8List();
  }

  /// Root-mean-square loudness of little-endian PCM16 samples, 0-1.
  static double rms(Uint8List pcm) {
    final samples = pcm.length ~/ 2;
    if (samples == 0) return 0;
    final data = ByteData.sublistView(pcm);
    var sum = 0.0;
    for (var i = 0; i < samples; i++) {
      final value = data.getInt16(i * 2, Endian.little) / 32768;
      sum += value * value;
    }
    return math.sqrt(sum / samples);
  }

  /// Seconds of audio in a WAV produced by [wav].
  static double seconds(Uint8List wav) =>
      wav.length <= 44 ? 0 : (wav.length - 44) / (sampleRate * 2);
}

/// Milliseconds from the press to the microphone really listening, for the
/// developer log (portal_assistant/docs/AI_CURRENT_RULES.md section 5, 2026-11-18): when
/// `start` returned, when the first chunk arrived, and when the first chunk
/// louder than [voiceLevel] arrived. Numbers only, never the audio. Printed
/// once per recording in debug and profile builds as one `TownPassMic:` line
/// (Android: logcat tag `flutter`; iOS: the console, and
/// on_device_assistant.log in on-device builds).
class MicTiming {
  /// Loudness (RMS) of a chunk counted as voice: the chat panel's
  /// "speak up" level.
  static const voiceLevel = 0.03;

  final _watch = Stopwatch();
  bool _prepared = false;
  int? startMs;
  int? firstChunkMs;
  int? firstVoiceMs;

  /// The press: the clock starts here (or at [begin] without a press).
  void press() {
    _watch
      ..reset()
      ..start();
    startMs = firstChunkMs = firstVoiceMs = null;
  }

  /// `start` began; [prepared]: it used a recorder made ahead of the press.
  void begin({required bool prepared}) {
    if (!_watch.isRunning) press();
    _prepared = prepared;
  }

  void started() => startMs ??= _watch.elapsedMilliseconds;

  void chunk(double level) {
    if (!_watch.isRunning) return;
    final now = _watch.elapsedMilliseconds;
    firstChunkMs ??= now;
    if (firstVoiceMs == null && level >= voiceLevel) firstVoiceMs = now;
  }

  /// The developer line, null when nothing was timed.
  String? line(String end) {
    if (!_watch.isRunning) return null;
    String ms(int? v) => v == null ? '-' : '${v}ms';
    return 'TownPassMic: prepared=${_prepared ? 1 : 0} '
        'start=${ms(startMs)} first_chunk=${ms(firstChunkMs)} '
        'first_voice=${ms(firstVoiceMs)} '
        'held=${_watch.elapsedMilliseconds}ms end=$end';
  }

  /// Prints [line] once (not in release builds) and stops the clock.
  void report(String end) {
    final text = line(end);
    _watch.stop();
    if (text != null && !kReleaseMode) debugPrint(text);
  }
}

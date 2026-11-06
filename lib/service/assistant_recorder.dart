import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// Hold-to-talk capture for the assistant: 16 kHz mono PCM16 kept in memory
/// and wrapped as WAV. Audio is never written to a file.
class AssistantRecorder {
  static const sampleRate = 16000;
  static const maxDuration = Duration(seconds: 30);
  static const _maxBytes = sampleRate * 2 * 30;

  /// Called with each chunk's loudness (RMS, 0-1) while recording.
  void Function(double level)? onLevel;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  BytesBuilder? _pcm;
  Completer<void>? _done;

  /// Starts capturing; false when the microphone permission is not granted.
  Future<bool> start() async {
    await cancel();
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) return false;
    final pcm = BytesBuilder(copy: false);
    final done = Completer<void>();
    _pcm = pcm;
    _done = done;
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _subscription = stream.listen(
      (chunk) {
        if (pcm.length < _maxBytes) pcm.add(chunk);
        onLevel?.call(rms(chunk));
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (_) => done.isCompleted ? null : done.complete(),
    );
    return true;
  }

  /// Stops and returns the recording as WAV, or null when nothing was captured.
  Future<Uint8List?> stop() async {
    final pcm = _pcm;
    final done = _done;
    _pcm = null;
    _done = null;
    if (pcm == null) return null;
    await _recorder?.stop();
    // Let the final buffered chunk arrive before closing the stream.
    await done?.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    await _subscription?.cancel();
    _subscription = null;
    return pcm.isEmpty ? null : wav(pcm.takeBytes());
  }

  /// Discards the current recording.
  Future<void> cancel() async {
    _pcm = null;
    _done = null;
    await _subscription?.cancel();
    _subscription = null;
    if (await _recorder?.isRecording() ?? false) await _recorder?.cancel();
  }

  Future<void> dispose() async {
    await cancel();
    await _recorder?.dispose();
    _recorder = null;
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

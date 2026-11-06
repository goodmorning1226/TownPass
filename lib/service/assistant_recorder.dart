import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// Hold-to-talk capture for the assistant: mono PCM16 kept in memory and
/// wrapped as a 16 kHz WAV. Audio is never written to a file.
///
/// Capture runs at 48 kHz, the native rate of Android audio hardware, and is
/// downsampled here. Asking the platform for 16 kHz directly produced audio
/// stretched about three times on the Android emulator (48 kHz data labelled
/// 16 kHz), which made speech unrecognisable.
class AssistantRecorder {
  static const sampleRate = 16000;
  static const captureRate = 48000;
  static const _factor = captureRate ~/ sampleRate;
  static const maxDuration = Duration(seconds: 30);
  static const _maxBytes = captureRate * 2 * 30;

  /// Called with each chunk's loudness (RMS, 0-1) while recording.
  void Function(double level)? onLevel;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  BytesBuilder? _pcm;
  Completer<void>? _done;

  /// Starts capturing; false when the microphone permission is not granted.
  ///
  /// Each recording uses a fresh platform recorder: reusing one across
  /// sessions risked the next session delivering silence.
  Future<bool> start() async {
    await cancel();
    await _recorder?.dispose();
    final recorder = _recorder = AudioRecorder();
    if (!await recorder.hasPermission()) return false;
    final pcm = BytesBuilder(copy: false);
    final done = Completer<void>();
    _pcm = pcm;
    _done = done;
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: captureRate,
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
    await _recorder?.dispose();
    _recorder = null;
    return pcm.isEmpty ? null : wav(downsample(pcm.takeBytes()));
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

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// One slice of microphone audio, with its loudness already measured.
///
/// The level travels with the bytes so that nothing downstream has to look at
/// them: the recogniser forwards [bytes] and reads [level], and never needs a
/// byte buffer of its own.
class AudioFrame {
  const AudioFrame({required this.bytes, required this.level});

  /// PCM16, mono, little-endian, at the rate the stream was opened with.
  final Uint8List bytes;

  /// Loudness, 0..1, for the listening animation.
  final double level;
}

/// The microphone, as the cloud recogniser needs it: a stream of frames.
///
/// AUDIO POLICY: this is one of exactly two files permitted to handle raw
/// audio, and the only one permitted to import `package:record`. It streams and
/// it never writes: `AudioRecorder.start(…, path:)` is the file-writing API and
/// is not used here, which `no_audio_persistence_test.dart` checks by reading
/// this source. The method is called [open] rather than `start` so that check
/// has no false positive to work around.
abstract interface class MicrophoneStream {
  Future<bool> hasPermission();

  /// Opens the microphone. Each frame is handed on and forgotten.
  Future<Stream<AudioFrame>> open({int sampleRate});

  Future<void> close();

  Future<void> dispose();
}

class RecordMicrophoneStream implements MicrophoneStream {
  RecordMicrophoneStream({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<AudioFrame>> open({int sampleRate = 16000}) async {
    final pcm = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    return pcm.map((bytes) => AudioFrame(bytes: bytes, level: rmsLevel(bytes)));
  }

  @override
  Future<void> close() => _recorder.cancel();

  @override
  Future<void> dispose() async => _recorder.dispose();
}

/// Loudness of one PCM16 buffer, as 0..1.
///
/// Pure, so it can be checked against a synthesised buffer rather than a
/// microphone.
double rmsLevel(Uint8List pcm16) {
  final view = ByteData.sublistView(pcm16);
  final samples = pcm16.lengthInBytes ~/ 2;
  if (samples == 0) return 0;

  // Every eighth sample: 2 kHz of arithmetic instead of 16 kHz, and no
  // animation can see the difference.
  const stride = 8;
  var sum = 0.0;
  var counted = 0;
  for (var i = 0; i < samples; i += stride) {
    final sample = view.getInt16(i * 2, Endian.little) / 32768.0;
    sum += sample * sample;
    counted++;
  }

  // Speech occupies a tiny slice of a linear amplitude scale, so map to dBFS
  // and normalise over a 50 dB window — otherwise the animation barely moves.
  // The platform path does the same thing more crudely with `level / 10`.
  final rms = math.sqrt(sum / counted);
  final decibels = 20 * math.log(rms + 1e-9) / math.ln10;
  return ((decibels + 50) / 50).clamp(0.0, 1.0);
}

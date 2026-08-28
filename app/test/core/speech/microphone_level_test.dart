import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/microphone_stream.dart';

/// Builds a PCM16 buffer of [samples] at the given amplitude, -1..1.
Uint8List tone(int samples, double amplitude) {
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    final value = (math.sin(i / 4) * amplitude * 32767).round();
    view.setInt16(i * 2, value, Endian.little);
  }
  return bytes;
}

void main() {
  group('rmsLevel', () {
    test('silence is nothing', () {
      expect(rmsLevel(Uint8List(3200)), 0);
    });

    test('an empty buffer is nothing rather than a crash', () {
      expect(rmsLevel(Uint8List(0)), 0);
    });

    test('a loud signal is near the top of the range', () {
      expect(rmsLevel(tone(1600, 1.0)), greaterThan(0.9));
    });

    test('a quiet signal sits below a loud one', () {
      expect(rmsLevel(tone(1600, 0.05)), lessThan(rmsLevel(tone(1600, 0.9))));
    });

    test('never leaves 0..1, whatever it is given', () {
      for (final amplitude in [0.0, 0.001, 0.5, 1.0]) {
        final level = rmsLevel(tone(1600, amplitude));
        expect(level, inInclusiveRange(0, 1));
      }
    });

    test('an odd-length buffer does not throw', () {
      // A truncated frame is a thing a real microphone can hand over.
      expect(() => rmsLevel(Uint8List(101)), returnsNormally);
    });
  });
}

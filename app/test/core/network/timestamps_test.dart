import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/network/timestamps.dart';

void main() {
  group('parseServerTimestamp', () {
    test('reads a zoneless timestamp as UTC, not as local time', () {
      // `DateTime.parse` would read this in the device's own zone. On a phone
      // two hours off UTC that moves the instant by two hours — enough to lose
      // a last-write-wins comparison and drop a change the user made.
      final parsed = parseServerTimestamp('2026-03-02T09:01:00');

      expect(parsed.isUtc, isTrue);
      expect(parsed, DateTime.utc(2026, 3, 2, 9, 1));
    });

    test('reads an explicit Z', () {
      expect(
        parseServerTimestamp('2026-03-02T09:01:00Z'),
        DateTime.utc(2026, 3, 2, 9, 1),
      );
    });

    test('reads an explicit offset and normalises it', () {
      expect(
        parseServerTimestamp('2026-03-02T11:01:00+02:00'),
        DateTime.utc(2026, 3, 2, 9, 1),
      );
      expect(
        parseServerTimestamp('2026-03-02T11:01:00+0200'),
        DateTime.utc(2026, 3, 2, 9, 1),
      );
    });

    test('keeps sub-second precision, which ties depend on', () {
      final parsed = parseServerTimestamp('2026-03-02T09:01:00.123456Z');

      expect(parsed.millisecond, 123);
    });

    test('null stays null', () {
      expect(parseServerTimestampOrNull(null), isNull);
      expect(parseServerTimestampOrNull(42), isNull);
    });
  });
}

/// Reading timestamps that came from the server.
///
/// The service states a zone on everything it sends. This is the belt to that
/// braces: a timestamp with no zone must be read as UTC, not as the device's
/// local time. `DateTime.parse` does the opposite — it treats a zoneless string
/// as local — and on a phone two hours off UTC that moves the instant by two
/// hours, which is enough to lose a last-write-wins comparison and silently
/// drop a change the user made.
library;

final _hasZone = RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$');

/// Parses a server timestamp as an instant in UTC.
DateTime parseServerTimestamp(String value) {
  final withZone = _hasZone.hasMatch(value) ? value : '${value}Z';
  return DateTime.parse(withZone).toUtc();
}

DateTime? parseServerTimestampOrNull(Object? value) =>
    value is String ? parseServerTimestamp(value) : null;

import 'package:uuid/uuid.dart';

/// Primary keys are generated on the device, never by the server, so a row can
/// be created offline and pushed later without renumbering.
///
/// UUIDv7 because it carries a millisecond timestamp in its high bits: ids sort
/// chronologically, which keeps SQLite's B-tree inserts sequential and makes
/// "the oldest unsynced row" a plain `ORDER BY id`.
abstract interface class IdGenerator {
  String newId();
}

class Uuid7Generator implements IdGenerator {
  const Uuid7Generator();

  static const _uuid = Uuid();

  @override
  String newId() => _uuid.v7();
}

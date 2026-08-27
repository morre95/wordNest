import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// The device's source of truth. The UI reads only from here; the sync engine
/// reconciles it with the backend whenever the backend is reachable, so the app
/// stays fully usable with the backend down.
@DriftDatabase(
  tables: [
    Utterances,
    GlossaryEntries,
    GlossaryOccurrences,
    ReviewLogs,
    SyncStates,
  ],
)
class WordNestDatabase extends _$WordNestDatabase {
  WordNestDatabase([QueryExecutor? executor])
      : super(executor ?? _openConnection());

  /// In-memory database for tests. Streams close synchronously so widget tests
  /// do not fail on a pending stream at teardown.
  WordNestDatabase.memory()
      : super(
          DatabaseConnection(
            NativeDatabase.memory(),
            closeStreamsSynchronously: true,
          ),
        );

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) async {
          await migrator.createAll();
          await into(syncStates).insert(
            SyncStatesCompanion.insert(id: const Value(1)),
          );
        },
        beforeOpen: (details) async {
          // Tombstones are only meaningful if the rows they point at survive,
          // and the glossary's example sentence must point at a real utterance.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  static QueryExecutor _openConnection() => driftDatabase(name: 'wordnest');
}

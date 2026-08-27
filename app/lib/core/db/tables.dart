import 'package:drift/drift.dart';

/// Columns every synced row carries.
///
/// This mixin is the reason the sync milestone needs no migration: every table
/// is born with a client-generated id, a modification timestamp, a tombstone
/// and an unsynced flag.
mixin SyncedRow on Table {
  /// Client-generated UUIDv7. Never reassigned, so a push is idempotent: a
  /// retried request after a dropped connection updates the same row.
  TextColumn get id => text()();

  /// Last local modification, in UTC. Used for last-write-wins on the fields
  /// where that is the correct rule.
  DateTimeColumn get updatedAt => dateTime()();

  /// Set instead of deleting the row, so a deletion propagates to other
  /// devices rather than being silently resurrected by them.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// True when the row has local changes the server has not acknowledged.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// How far an utterance has got through backend enrichment.
enum EnrichmentState {
  /// Translated on-device only. Queued for the backend.
  pending,

  /// The backend returned a translation and a word breakdown.
  enriched,

  /// The backend rejected it; the on-device translation stands.
  failed,
}

/// One finalised thing the user said.
///
/// Immutable once finalised, apart from the enrichment fields, which only the
/// originating device ever writes. That is what makes utterances append-only
/// and conflict-free during sync.
@DataClassName('Utterance')
class Utterances extends Table with SyncedRow {
  TextColumn get sourceText => text()();
  TextColumn get translationText => text()();

  /// A word-for-word rendering, when the backend supplies one. Null offline.
  TextColumn get literalGloss => text().nullable()();

  TextColumn get sourceLanguage => text().withLength(min: 2, max: 8)();
  TextColumn get targetLanguage => text().withLength(min: 2, max: 8)();

  /// When the user said it, as opposed to when the row was written.
  DateTimeColumn get spokenAt => dateTime()();

  TextColumn get enrichmentState =>
      textEnum<EnrichmentState>().withDefault(const Constant('pending'))();

  /// The user's explicit "this one was hard" signal on a whole sentence.
  BoolColumn get isFlagged => boolean().withDefault(const Constant(false))();

  @override
  List<String> get customConstraints => const [
        "CHECK (source_language <> target_language)",
      ];
}

/// A word the user has produced, kept once per lemma per language pair.
///
/// The only genuinely mergeable row type, which is why its fields are split by
/// merge rule: [seenCount] is recomputed from [GlossaryOccurrences], [isFlagged]
/// is last-write-wins, and the scheduling fields follow [lastReviewedAt].
@DataClassName('GlossaryEntry')
class GlossaryEntries extends Table with SyncedRow {
  /// The dictionary form. Filled by the backend's lemmatiser; offline it is
  /// the lowercased surface form, and is corrected when enrichment arrives.
  TextColumn get lemma => text()();

  /// How the word appeared the first time it was heard.
  TextColumn get surfaceForm => text()();

  /// Universal Dependencies tag (`NOUN`, `VERB`, …). Null until enriched.
  TextColumn get partOfSpeech => text().nullable()();

  /// The word in the target language. Null until enriched.
  TextColumn get targetForm => text().nullable()();

  TextColumn get sourceLanguage => text().withLength(min: 2, max: 8)();
  TextColumn get targetLanguage => text().withLength(min: 2, max: 8)();

  /// Derived from the occurrence rows. Stored so the glossary can sort on it
  /// without a join, and recomputed after every merge.
  IntColumn get seenCount => integer().withDefault(const Constant(0))();

  /// The sentence shown as the example. Points at the most recent occurrence.
  TextColumn get exampleUtteranceId =>
      text().nullable().references(Utterances, #id)();

  /// The user's explicit difficulty signal. Last-write-wins on [updatedAt].
  BoolColumn get isFlagged => boolean().withDefault(const Constant(false))();

  // --- SM-2 scheduling state (milestone 5) ---
  // Present from the first migration so review data never needs a schema
  // change, and so the merge rules can be written once.

  /// Days until the next review. 0 for an entry never reviewed.
  IntColumn get intervalDays => integer().withDefault(const Constant(0))();

  /// SM-2 ease factor. 2.5 is the algorithm's starting value.
  RealColumn get easeFactor => real().withDefault(const Constant(2.5))();

  /// Consecutive successful reviews. Reset to 0 by a lapse.
  IntColumn get repetitionCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get dueAt => dateTime().nullable()();

  /// The tiebreaker when two devices both reviewed offline.
  DateTimeColumn get lastReviewedAt => dateTime().nullable()();

  @override
  List<String> get customConstraints => const [
        // One entry per word per direction. This is what makes a repeated word
        // increment a count instead of creating a duplicate, and it is enforced
        // here rather than in Dart because two isolates can race.
        'UNIQUE (lemma, source_language, target_language)',
        'CHECK (ease_factor >= 1.3)',
        'CHECK (seen_count >= 0)',
      ];
}

/// One sighting of a glossary entry in one utterance.
///
/// Exists so [GlossaryEntries.seenCount] can be recomputed rather than merged:
/// two devices that each heard the word twice offline should converge on four,
/// which counting rows gives for free and copying a number does not.
@DataClassName('GlossaryOccurrence')
class GlossaryOccurrences extends Table with SyncedRow {
  TextColumn get glossaryEntryId => text().references(GlossaryEntries, #id)();
  TextColumn get utteranceId => text().references(Utterances, #id)();

  /// The inflected form used in that sentence, which may differ from the lemma.
  TextColumn get surfaceForm => text()();

  @override
  List<String> get customConstraints => const [
        'UNIQUE (glossary_entry_id, utterance_id)',
      ];
}

/// An immutable record that a review happened.
///
/// Append-only and deduplicated by id, so two devices reviewing offline both
/// contribute rather than one overwriting the other.
@DataClassName('ReviewLog')
class ReviewLogs extends Table with SyncedRow {
  TextColumn get glossaryEntryId => text().references(GlossaryEntries, #id)();
  DateTimeColumn get reviewedAt => dateTime()();

  /// SM-2 grade, 0–5. Below 3 is a lapse.
  IntColumn get grade => integer()();

  /// The interval this review scheduled, kept so the schedule can be rebuilt
  /// from the log alone if the entry's state is ever lost or merged away.
  IntColumn get scheduledIntervalDays => integer()();
  RealColumn get scheduledEaseFactor => real()();

  @override
  List<String> get customConstraints => const [
        'CHECK (grade BETWEEN 0 AND 5)',
      ];
}

/// Single-row table holding where sync got to. Not itself synced.
class SyncStates extends Table {
  /// Always 1. Keeps the table to one row.
  IntColumn get id => integer().withDefault(const Constant(1))();

  /// The server's monotonic sequence number we have pulled up to. Wall-clock
  /// time is deliberately not used: device clocks drift, and a client syncing
  /// in the same millisecond as a write would miss it.
  IntColumn get cursor => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastSyncedAt => dateTime().nullable()();

  /// The last sync failure, for the status line in settings. Null when the
  /// last attempt succeeded.
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => const ['CHECK (id = 1)'];
}

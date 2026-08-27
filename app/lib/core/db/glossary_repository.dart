import 'package:drift/drift.dart';

import '../clock.dart';
import '../ids/id_generator.dart';
import '../vocabulary/vocabulary_extractor.dart';
import 'database.dart';

/// How the glossary list is ordered.
enum GlossarySort {
  /// Most recently heard first — what the user just said, at the top.
  recency,

  /// Hardest first: flagged words, then low ease, then overdue.
  struggle,

  /// Alphabetical by lemma.
  alphabetical,
}

/// Which entries to show.
enum GlossaryDifficulty {
  all,

  /// Only entries the user flagged, or whose review performance is poor.
  struggling,

  /// Entries that are due or overdue for review.
  due,
}

/// A glossary entry together with the sentence it came from, which is what the
/// list and detail view both need.
class GlossaryEntryWithExample {
  const GlossaryEntryWithExample({required this.entry, this.example});

  final GlossaryEntry entry;
  final Utterance? example;
}

/// Reads and writes the personal glossary.
///
/// [recordWords] is the only writer that runs on the speaking path, and it is
/// designed to be called inside the utterance transaction.
class GlossaryRepository {
  GlossaryRepository({
    required WordNestDatabase database,
    IdGenerator idGenerator = const Uuid7Generator(),
    Clock clock = systemClock,
  })  : _db = database,
        _ids = idGenerator,
        _now = clock;

  /// An entry is "struggling" below this ease factor. SM-2 starts entries at
  /// 2.5 and subtracts on every poor answer, so 2.0 is roughly "got it wrong
  /// twice".
  static const strugglingEaseFactor = 2.0;

  final WordNestDatabase _db;
  final IdGenerator _ids;
  final Clock _now;

  /// Folds the words of one utterance into the glossary.
  ///
  /// A word already in the glossary gains an occurrence and a fresher example
  /// rather than a duplicate row. The seen count is then recomputed from the
  /// occurrence rows, never incremented in place — that is what lets two
  /// offline devices converge on the right total when they sync.
  Future<void> recordWords(
    List<ExtractedWord> words, {
    required Utterance utterance,
  }) async {
    if (words.isEmpty) return;
    final now = _now();

    await _db.transaction(() async {
      for (final word in words) {
        final entry = await _upsertEntry(word, utterance: utterance, now: now);
        await _db.into(_db.glossaryOccurrences).insert(
              GlossaryOccurrencesCompanion.insert(
                id: _ids.newId(),
                glossaryEntryId: entry.id,
                utteranceId: utterance.id,
                surfaceForm: word.surfaceForm,
                updatedAt: now,
              ),
              // The same word twice in one sentence is one occurrence.
              mode: InsertMode.insertOrIgnore,
            );
        await recomputeSeenCount(entry.id);
      }
    });
  }

  Future<GlossaryEntry> _upsertEntry(
    ExtractedWord word, {
    required Utterance utterance,
    required DateTime now,
  }) async {
    final existing = await (_db.select(_db.glossaryEntries)
          ..where((row) =>
              row.lemma.equals(word.lemma) &
              row.sourceLanguage.equals(utterance.sourceLanguage) &
              row.targetLanguage.equals(utterance.targetLanguage)))
        .getSingleOrNull();

    if (existing != null) {
      // Point the example at the newest sentence: a fresh context is more
      // useful for recall than the first one ever heard. Un-delete, too — the
      // user saying the word again is a clearer signal than an old tombstone.
      await (_db.update(_db.glossaryEntries)
            ..where((row) => row.id.equals(existing.id)))
          .write(
        GlossaryEntriesCompanion(
          exampleUtteranceId: Value(utterance.id),
          deletedAt: const Value(null),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
      return existing;
    }

    return _db.into(_db.glossaryEntries).insertReturning(
          GlossaryEntriesCompanion.insert(
            id: _ids.newId(),
            lemma: word.lemma,
            surfaceForm: word.surfaceForm,
            sourceLanguage: utterance.sourceLanguage,
            targetLanguage: utterance.targetLanguage,
            exampleUtteranceId: Value(utterance.id),
            updatedAt: now,
          ),
        );
  }

  /// Recounts the live occurrences of an entry and stores the result.
  ///
  /// Called after every write and after every sync merge, so the stored count
  /// is always derivable and never a number two devices had to agree on.
  Future<void> recomputeSeenCount(String entryId) async {
    final count = _db.glossaryOccurrences.id.count();
    final query = _db.selectOnly(_db.glossaryOccurrences)
      ..addColumns([count])
      ..where(_db.glossaryOccurrences.glossaryEntryId.equals(entryId) &
          _db.glossaryOccurrences.deletedAt.isNull());
    final total = (await query.getSingle()).read(count) ?? 0;

    await (_db.update(_db.glossaryEntries)
          ..where((row) => row.id.equals(entryId)))
        .write(GlossaryEntriesCompanion(seenCount: Value(total)));
  }

  /// The glossary list, filtered and sorted, as a live stream.
  ///
  /// [search] matches the lemma, the surface form and the target-language form,
  /// so a user can find a word by whichever side they remember.
  Stream<List<GlossaryEntryWithExample>> watchEntries({
    String search = '',
    String? languagePairKey,
    GlossaryDifficulty difficulty = GlossaryDifficulty.all,
    GlossarySort sort = GlossarySort.recency,
    int limit = 200,
  }) {
    final entries = _db.glossaryEntries;
    final utterances = _db.utterances;
    final now = _now();

    final query = _db.select(entries).join([
      leftOuterJoin(
        utterances,
        utterances.id.equalsExp(entries.exampleUtteranceId),
      ),
    ]);

    query.where(entries.deletedAt.isNull());

    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      final pattern = '%$term%';
      query.where(
        entries.lemma.lower().like(pattern) |
            entries.surfaceForm.lower().like(pattern) |
            entries.targetForm.lower().like(pattern),
      );
    }

    if (languagePairKey != null) {
      final parts = languagePairKey.split('-');
      if (parts.length == 2) {
        query.where(entries.sourceLanguage.equals(parts[0]) &
            entries.targetLanguage.equals(parts[1]));
      }
    }

    switch (difficulty) {
      case GlossaryDifficulty.all:
        break;
      case GlossaryDifficulty.struggling:
        query.where(entries.isFlagged.equals(true) |
            entries.easeFactor.isSmallerThanValue(strugglingEaseFactor));
      case GlossaryDifficulty.due:
        query.where(entries.dueAt.isSmallerOrEqualValue(now));
    }

    query.orderBy(switch (sort) {
      GlossarySort.recency => [OrderingTerm.desc(entries.updatedAt)],
      GlossarySort.alphabetical => [OrderingTerm.asc(entries.lemma)],
      // Flagged first, then least-well-known, then most-often-stumbled-over.
      GlossarySort.struggle => [
          OrderingTerm.desc(entries.isFlagged),
          OrderingTerm.asc(entries.easeFactor),
          OrderingTerm.desc(entries.seenCount),
        ],
    });
    query.limit(limit);

    return query.watch().map(
          (rows) => rows
              .map((row) => GlossaryEntryWithExample(
                    entry: row.readTable(entries),
                    example: row.readTableOrNull(utterances),
                  ))
              .toList(growable: false),
        );
  }

  Stream<GlossaryEntryWithExample?> watchEntry(String id) {
    final entries = _db.glossaryEntries;
    final utterances = _db.utterances;
    final query = _db.select(entries).join([
      leftOuterJoin(
        utterances,
        utterances.id.equalsExp(entries.exampleUtteranceId),
      ),
    ])
      // A tombstoned entry reads as gone: the detail view must say the word has
      // been removed rather than showing a row that is on its way out.
      ..where(entries.id.equals(id) & entries.deletedAt.isNull());

    return query.watchSingleOrNull().map(
          (row) => row == null
              ? null
              : GlossaryEntryWithExample(
                  entry: row.readTable(entries),
                  example: row.readTableOrNull(utterances),
                ),
        );
  }

  /// Every sentence this word has appeared in, newest first.
  Stream<List<Utterance>> watchOccurrences(String entryId, {int limit = 20}) {
    final occurrences = _db.glossaryOccurrences;
    final utterances = _db.utterances;
    final query = _db.select(occurrences).join([
      innerJoin(utterances, utterances.id.equalsExp(occurrences.utteranceId)),
    ])
      ..where(occurrences.glossaryEntryId.equals(entryId) &
          occurrences.deletedAt.isNull() &
          utterances.deletedAt.isNull())
      ..orderBy([OrderingTerm.desc(utterances.spokenAt)])
      ..limit(limit);

    return query.watch().map(
          (rows) => rows.map((row) => row.readTable(utterances)).toList(),
        );
  }

  /// The user's explicit "this one is hard" signal.
  Future<void> setFlagged(String entryId, {required bool isFlagged}) async {
    await (_db.update(_db.glossaryEntries)
          ..where((row) => row.id.equals(entryId)))
        .write(
      GlossaryEntriesCompanion(
        isFlagged: Value(isFlagged),
        updatedAt: Value(_now()),
        dirty: const Value(true),
      ),
    );
  }

  Future<void> delete(String entryId) async {
    final now = _now();
    await (_db.update(_db.glossaryEntries)
          ..where((row) => row.id.equals(entryId)))
        .write(
      GlossaryEntriesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// The language pairs the glossary actually contains, for the filter.
  Stream<List<String>> watchLanguagePairKeys() {
    final entries = _db.glossaryEntries;
    final query = _db.selectOnly(entries, distinct: true)
      ..addColumns([entries.sourceLanguage, entries.targetLanguage])
      ..where(entries.deletedAt.isNull());

    return query.watch().map(
          (rows) => rows
              .map((row) =>
                  '${row.read(entries.sourceLanguage)}-${row.read(entries.targetLanguage)}')
              .toList(growable: false),
        );
  }

  Future<int> count() async {
    final total = _db.glossaryEntries.id.count();
    final query = _db.selectOnly(_db.glossaryEntries)
      ..addColumns([total])
      ..where(_db.glossaryEntries.deletedAt.isNull());
    return (await query.getSingle()).read(total) ?? 0;
  }
}

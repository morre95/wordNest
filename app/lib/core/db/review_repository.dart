import 'package:drift/drift.dart';

import '../clock.dart';
import '../ids/id_generator.dart';
import '../review/scheduler.dart';
import 'database.dart';
import 'glossary_repository.dart';

/// One word to review, with everything the screen needs to show it.
class ReviewCard {
  const ReviewCard({
    required this.entry,
    required this.state,
    this.example,
  });

  final GlossaryEntry entry;
  final SchedulingState state;

  /// The sentence the user originally said it in — the context that makes a
  /// word recallable rather than a flashcard.
  final Utterance? example;
}

/// Reading the review queue and recording what happened.
///
/// The scheduling itself is in `core/review/scheduler.dart` and is pure; this
/// class supplies it with state and stores what it returns.
class ReviewRepository {
  ReviewRepository({
    required WordNestDatabase database,
    IdGenerator idGenerator = const Uuid7Generator(),
    Clock clock = systemClock,
  })  : _db = database,
        _ids = idGenerator,
        _now = clock;

  /// One session's worth. Long enough to be useful, short enough to finish.
  static const defaultSessionSize = 20;

  final WordNestDatabase _db;
  final IdGenerator _ids;
  final Clock _now;

  /// The words to review now, most urgent first.
  ///
  /// Ordered in Dart rather than SQL because the priority is a function of the
  /// current time, the flag and the ease factor together — expressible in SQL,
  /// but then the rule would live in two places and only one of them tested.
  Future<List<ReviewCard>> dueCards({int limit = defaultSessionSize}) async {
    final now = _now();
    final entries = _db.glossaryEntries;
    final utterances = _db.utterances;

    final rows = await (_db.select(entries).join([
      leftOuterJoin(
        utterances,
        utterances.id.equalsExp(entries.exampleUtteranceId),
      ),
    ])
          ..where(
            entries.deletedAt.isNull() &
                // Never reviewed, or due. A word the user flagged is always
                // worth offering even if its schedule says otherwise.
                (entries.dueAt.isNull() |
                    entries.dueAt.isSmallerOrEqualValue(now) |
                    entries.isFlagged.equals(true)),
          )
          // A generous ceiling before sorting in Dart, so a large glossary does
          // not have to be loaded in full.
          ..limit(limit * 10))
        .get();

    final cards = rows.map((row) {
      final entry = row.readTable(entries);
      return ReviewCard(
        entry: entry,
        state: schedulingStateOf(entry),
        example: row.readTableOrNull(utterances),
      );
    }).toList();

    cards.sort((left, right) {
      final byPriority = reviewPriority(
        state: right.state,
        isFlagged: right.entry.isFlagged,
        now: now,
      ).compareTo(
        reviewPriority(
          state: left.state,
          isFlagged: left.entry.isFlagged,
          now: now,
        ),
      );
      if (byPriority != 0) return byPriority;
      // A stable tiebreak, so the same queue does not shuffle between builds.
      return left.entry.id.compareTo(right.entry.id);
    });

    return cards.take(limit).toList(growable: false);
  }

  /// How many words are waiting, for the badge on the review entry point.
  Stream<int> watchDueCount() {
    final entries = _db.glossaryEntries;
    final count = entries.id.count();
    final query = _db.selectOnly(entries)
      ..addColumns([count])
      ..where(
        entries.deletedAt.isNull() &
            (entries.dueAt.isNull() |
                entries.dueAt.isSmallerOrEqualValue(_now()) |
                entries.isFlagged.equals(true)),
      );
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  /// Records a review: an immutable log row, and the new schedule on the entry.
  ///
  /// One transaction, because a log without its schedule would replay the
  /// review on the next sync and a schedule without its log would be
  /// unexplainable.
  Future<SchedulingState> recordReview(
    GlossaryEntry entry, {
    required ReviewGrade grade,
  }) async {
    final now = _now();
    final next = schedule(
      schedulingStateOf(entry),
      grade: grade,
      reviewedAt: now,
    );

    await _db.transaction(() async {
      await _db.into(_db.reviewLogs).insert(
            ReviewLogsCompanion.insert(
              id: _ids.newId(),
              glossaryEntryId: entry.id,
              reviewedAt: now,
              grade: grade.quality,
              scheduledIntervalDays: next.intervalDays,
              scheduledEaseFactor: next.easeFactor,
              updatedAt: now,
            ),
          );
      await (_db.update(_db.glossaryEntries)
            ..where((row) => row.id.equals(entry.id)))
          .write(
        GlossaryEntriesCompanion(
          intervalDays: Value(next.intervalDays),
          easeFactor: Value(next.easeFactor),
          repetitionCount: Value(next.repetitionCount),
          dueAt: Value(next.dueAt),
          lastReviewedAt: Value(next.lastReviewedAt),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
    });

    return next;
  }

  /// Everything the statistics screen shows, in one pass.
  Future<GlossaryStatistics> statistics() async {
    final now = _now();
    final entries = _db.glossaryEntries;

    final rows = await (_db.select(entries)
          ..where((row) => row.deletedAt.isNull()))
        .get();
    final reviewCount = await _db.reviewLogs.count().getSingle();
    final utteranceCount = await (_db.selectOnly(_db.utterances)
          ..addColumns([_db.utterances.id.count()])
          ..where(_db.utterances.deletedAt.isNull()))
        .getSingle()
        .then((row) => row.read(_db.utterances.id.count()) ?? 0);

    return GlossaryStatistics(
      wordCount: rows.length,
      utteranceCount: utteranceCount,
      reviewCount: reviewCount,
      dueCount: rows
          .where((row) =>
              row.isFlagged || schedulingStateOf(row).isDueAt(now))
          .length,
      strugglingCount: rows
          .where((row) =>
              row.isFlagged ||
              row.easeFactor < GlossaryRepository.strugglingEaseFactor)
          .length,
      learnedCount: rows.where((row) => row.repetitionCount >= 3).length,
      languagePairs: rows
          .map((row) => '${row.sourceLanguage}-${row.targetLanguage}')
          .toSet()
          .length,
    );
  }
}

/// Reads the scheduling columns off a row into the scheduler's own type.
SchedulingState schedulingStateOf(GlossaryEntry entry) => SchedulingState(
      intervalDays: entry.intervalDays,
      easeFactor: entry.easeFactor,
      repetitionCount: entry.repetitionCount,
      lastReviewedAt: entry.lastReviewedAt,
      dueAt: entry.dueAt,
    );

/// What the glossary looks like as a whole.
class GlossaryStatistics {
  const GlossaryStatistics({
    required this.wordCount,
    required this.utteranceCount,
    required this.reviewCount,
    required this.dueCount,
    required this.strugglingCount,
    required this.learnedCount,
    required this.languagePairs,
  });

  final int wordCount;
  final int utteranceCount;
  final int reviewCount;
  final int dueCount;
  final int strugglingCount;

  /// Recalled three times running — far enough along to feel like progress.
  final int learnedCount;
  final int languagePairs;

  bool get isEmpty => wordCount == 0;
}

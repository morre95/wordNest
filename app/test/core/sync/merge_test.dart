import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/sync/merge.dart';

/// The device's half of the merge rules, against the same named cases the
/// server's suite uses. If one side changes, the other must change with it.
void main() {
  final monday = DateTime.utc(2026, 3, 2, 9);
  final tuesday = monday.add(const Duration(days: 1));
  final wednesday = monday.add(const Duration(days: 2));

  UtteranceSnapshot utterance({
    DateTime? updatedAt,
    String sourceText = 'the bakery is closed',
    String translationText = 'la panadería está cerrada',
    String enrichmentState = 'pending',
    bool isFlagged = false,
    DateTime? deletedAt,
  }) {
    return UtteranceSnapshot(
      id: 'utterance-1',
      updatedAt: updatedAt ?? monday,
      sourceText: sourceText,
      translationText: translationText,
      enrichmentState: enrichmentState,
      isFlagged: isFlagged,
      deletedAt: deletedAt,
    );
  }

  GlossaryEntrySnapshot entry({
    String id = 'entry-1',
    String lemma = 'bakery',
    String? partOfSpeech,
    String? targetForm,
    int seenCount = 1,
    bool isFlagged = false,
    int intervalDays = 0,
    double easeFactor = 2.5,
    int repetitionCount = 0,
    DateTime? dueAt,
    DateTime? lastReviewedAt,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) {
    return GlossaryEntrySnapshot(
      id: id,
      lemma: lemma,
      surfaceForm: lemma,
      partOfSpeech: partOfSpeech,
      targetForm: targetForm,
      sourceLanguage: 'en',
      targetLanguage: 'es',
      seenCount: seenCount,
      isFlagged: isFlagged,
      intervalDays: intervalDays,
      easeFactor: easeFactor,
      repetitionCount: repetitionCount,
      dueAt: dueAt,
      lastReviewedAt: lastReviewedAt,
      updatedAt: updatedAt ?? monday,
      deletedAt: deletedAt,
    );
  }

  ReviewLogSnapshot reviewLog({String id = 'review-1', int grade = 4}) {
    return ReviewLogSnapshot(
      id: id,
      glossaryEntryId: 'entry-1',
      reviewedAt: monday,
      grade: grade,
      scheduledIntervalDays: 1,
      scheduledEaseFactor: 2.5,
      updatedAt: monday,
    );
  }

  GlossaryOccurrenceSnapshot occurrence({
    String glossaryEntryId = 'entry-1',
    DateTime? updatedAt,
  }) {
    return GlossaryOccurrenceSnapshot(
      id: 'occurrence-1',
      glossaryEntryId: glossaryEntryId,
      utteranceId: 'utterance-1',
      surfaceForm: 'bakery',
      updatedAt: updatedAt ?? monday,
    );
  }

  group('utterances', () {
    test('a row not held locally is inserted', () {
      final result = mergeUtterance(local: null, remote: utterance());

      expect(result.outcome, MergeOutcome.inserted);
    });

    test('enrichment arriving from the other device replaces the row', () {
      final result = mergeUtterance(
        local: utterance(),
        remote: utterance(
          updatedAt: tuesday,
          translationText: 'la panadería ha cerrado',
          enrichmentState: 'enriched',
        ),
      );

      expect(result.outcome, MergeOutcome.replaced);
      expect(result.value.translationText, 'la panadería ha cerrado');
    });

    test('an older copy does not undo a newer one', () {
      final result = mergeUtterance(
        local: utterance(updatedAt: wednesday, enrichmentState: 'enriched'),
        remote: utterance(updatedAt: monday),
      );

      expect(result.outcome, MergeOutcome.kept);
      expect(result.shouldWrite, isFalse);
    });

    test('the same row pulled twice writes nothing', () {
      final result = mergeUtterance(local: utterance(), remote: utterance());

      expect(result.shouldWrite, isFalse);
    });
  });

  group('review logs', () {
    test('a review not held locally is recorded', () {
      expect(
        mergeReviewLog(local: null, remote: reviewLog()).outcome,
        MergeOutcome.inserted,
      );
    });

    test('an event never changes after the fact', () {
      final result = mergeReviewLog(
        local: reviewLog(),
        remote: reviewLog(grade: 1),
      );

      expect(result.outcome, MergeOutcome.kept);
      expect(result.value.grade, 4);
    });

    test('two devices reviewing offline both contribute', () {
      expect(
        mergeReviewLog(local: null, remote: reviewLog(id: 'review-a')).outcome,
        MergeOutcome.inserted,
      );
      expect(
        mergeReviewLog(local: null, remote: reviewLog(id: 'review-b')).outcome,
        MergeOutcome.inserted,
      );
    });
  });

  group('glossary entries', () {
    test('a new entry gets a due date derived from its schedule', () {
      final result = mergeGlossaryEntry(
        local: null,
        remote: entry(lastReviewedAt: monday, intervalDays: 3),
      );

      expect(result.value.dueAt, monday.add(const Duration(days: 3)));
    });

    test('the seen count is never copied across', () {
      final result = mergeGlossaryEntry(
        local: entry(seenCount: 2),
        remote: entry(seenCount: 7, updatedAt: tuesday),
      );

      expect(result.value.seenCount, 2);
    });

    test("the user's flag is last-write-wins", () {
      expect(
        mergeGlossaryEntry(
          local: entry(isFlagged: false),
          remote: entry(isFlagged: true, updatedAt: tuesday),
        ).value.isFlagged,
        isTrue,
      );
      expect(
        mergeGlossaryEntry(
          local: entry(isFlagged: true, updatedAt: wednesday),
          remote: entry(isFlagged: false, updatedAt: monday),
        ).value.isFlagged,
        isTrue,
      );
    });

    test('a tie leaves the local row alone', () {
      final result = mergeGlossaryEntry(local: entry(), remote: entry());

      expect(result.outcome, MergeOutcome.kept);
      expect(result.shouldWrite, isFalse);
    });

    test('the schedule follows whoever reviewed most recently', () {
      final result = mergeGlossaryEntry(
        local: entry(
          lastReviewedAt: monday,
          intervalDays: 1,
          repetitionCount: 1,
          updatedAt: wednesday,
        ),
        remote: entry(
          lastReviewedAt: tuesday,
          intervalDays: 6,
          easeFactor: 2.6,
          repetitionCount: 2,
        ),
      );

      expect(result.value.intervalDays, 6);
      expect(result.value.easeFactor, closeTo(2.6, 0.001));
      expect(result.value.repetitionCount, 2);
    });

    test('the schedule moves as one block', () {
      // Taking the interval from one side and the ease from the other would
      // produce a schedule neither device ever computed.
      final result = mergeGlossaryEntry(
        local: entry(lastReviewedAt: tuesday, intervalDays: 10, easeFactor: 2.9),
        remote: entry(
          lastReviewedAt: monday,
          intervalDays: 1,
          easeFactor: 1.7,
          updatedAt: wednesday,
        ),
      );

      expect(result.value.intervalDays, 10);
      expect(result.value.easeFactor, closeTo(2.9, 0.001));
    });

    test('a stale due date cannot resurface a word already scheduled out', () {
      final result = mergeGlossaryEntry(
        local: entry(
          lastReviewedAt: tuesday,
          intervalDays: 10,
          dueAt: tuesday.add(const Duration(days: 10)),
        ),
        remote: entry(
          lastReviewedAt: monday,
          intervalDays: 0,
          dueAt: monday,
          updatedAt: wednesday,
        ),
      );

      expect(result.value.dueAt, tuesday.add(const Duration(days: 10)));
    });

    test('enrichment from the other device is taken', () {
      final result = mergeGlossaryEntry(
        local: entry(),
        remote: entry(
          partOfSpeech: 'NOUN',
          targetForm: 'panadería',
          updatedAt: tuesday,
        ),
      );

      expect(result.value.partOfSpeech, 'NOUN');
      expect(result.value.targetForm, 'panadería');
    });
  });

  group('the awkward cases', () {
    test('the same word learned independently on two offline devices', () {
      final learnedHere = entry(id: 'entry-local', seenCount: 2);
      final learnedThere = entry(
        id: 'entry-remote',
        seenCount: 3,
        targetForm: 'panadería',
        updatedAt: tuesday,
      );

      final result =
          mergeGlossaryEntry(local: learnedHere, remote: learnedThere);

      expect(result.value.id, 'entry-local', reason: 'identity is local');
      expect(result.value.targetForm, 'panadería');
      expect(result.value.seenCount, 2, reason: 'recomputed, never copied');
    });

    test('a review on device A and an edit on device B between syncs', () {
      final reviewedHere = entry(
        lastReviewedAt: tuesday,
        intervalDays: 6,
        easeFactor: 2.6,
        repetitionCount: 2,
        updatedAt: tuesday,
      );
      final flaggedThere = entry(isFlagged: true, updatedAt: wednesday);

      final result =
          mergeGlossaryEntry(local: reviewedHere, remote: flaggedThere);

      expect(result.outcome, MergeOutcome.merged);
      expect(result.value.isFlagged, isTrue);
      expect(result.value.intervalDays, 6);
      expect(result.value.dueAt, tuesday.add(const Duration(days: 6)));
    });

    test('a deletion racing an update settles the same way in both orders', () {
      final deleted = entry(deletedAt: wednesday, updatedAt: wednesday);
      final edited = entry(isFlagged: true, updatedAt: tuesday);

      expect(
        mergeGlossaryEntry(local: edited, remote: deleted).value.deletedAt,
        wednesday,
      );
      expect(
        mergeGlossaryEntry(local: deleted, remote: edited).value.deletedAt,
        wednesday,
      );
    });

    test('a deleted word said again on the other device comes back', () {
      final result = mergeGlossaryEntry(
        local: entry(deletedAt: monday),
        remote: entry(updatedAt: wednesday),
      );

      expect(result.value.deletedAt, isNull);
    });

    test('a fortnight of queued changes converges whatever the order', () {
      final start = entry();
      final backlog = [
        entry(isFlagged: true, updatedAt: monday.add(const Duration(days: 3))),
        entry(
          lastReviewedAt: monday.add(const Duration(days: 5)),
          intervalDays: 4,
          updatedAt: monday.add(const Duration(days: 5)),
        ),
        entry(
          targetForm: 'panadería',
          updatedAt: monday.add(const Duration(days: 14)),
        ),
      ];

      var forwards = start;
      for (final change in backlog) {
        forwards = mergeGlossaryEntry(local: forwards, remote: change).value;
      }
      var backwards = start;
      for (final change in backlog.reversed) {
        backwards = mergeGlossaryEntry(local: backwards, remote: change).value;
      }

      expect(forwards, backwards, reason: 'order must not change the answer');
      expect(forwards.targetForm, 'panadería');
      expect(forwards.intervalDays, 4);
    });
  });

  group('occurrences', () {
    test('a new sighting is recorded', () {
      expect(
        mergeGlossaryOccurrence(local: null, remote: occurrence()).outcome,
        MergeOutcome.inserted,
      );
    });

    test('the same sighting pulled twice writes nothing', () {
      expect(
        mergeGlossaryOccurrence(local: occurrence(), remote: occurrence())
            .shouldWrite,
        isFalse,
      );
    });

    test('a re-keyed occurrence follows its new entry', () {
      final result = mergeGlossaryOccurrence(
        local: occurrence(glossaryEntryId: 'entry-opens'),
        remote: occurrence(
          glossaryEntryId: 'entry-open',
          updatedAt: tuesday,
        ),
      );

      expect(result.value.glossaryEntryId, 'entry-open');
    });
  });

  group('due dates', () {
    test('an entry never reviewed has no due date', () {
      expect(dueDateFrom(lastReviewedAt: null, intervalDays: 5), isNull);
    });

    test('a zero interval is due immediately', () {
      expect(dueDateFrom(lastReviewedAt: monday, intervalDays: 0), monday);
    });

    test('a negative interval cannot schedule into the past', () {
      expect(dueDateFrom(lastReviewedAt: monday, intervalDays: -5), monday);
    });
  });
}

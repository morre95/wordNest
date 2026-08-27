import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/review/scheduler.dart';

void main() {
  final monday = DateTime.utc(2026, 3, 2, 9);

  SchedulingState reviewOn(
    SchedulingState state,
    ReviewGrade grade, {
    DateTime? at,
  }) {
    return schedule(state, grade: grade, reviewedAt: at ?? monday);
  }

  group('the first reviews of a new word', () {
    test('a word never reviewed is due immediately', () {
      expect(const SchedulingState().isDueAt(monday), isTrue);
    });

    test('the first success schedules it for tomorrow', () {
      final state = reviewOn(const SchedulingState(), ReviewGrade.good);

      expect(state.intervalDays, 1);
      expect(state.repetitionCount, 1);
      expect(state.dueAt, monday.add(const Duration(days: 1)));
    });

    test('the second success schedules it for six days out', () {
      var state = reviewOn(const SchedulingState(), ReviewGrade.good);
      state = reviewOn(state, ReviewGrade.good, at: state.dueAt);

      expect(state.intervalDays, 6);
      expect(state.repetitionCount, 2);
    });

    test('from the third, the interval grows by the ease factor', () {
      var state = reviewOn(const SchedulingState(), ReviewGrade.good);
      state = reviewOn(state, ReviewGrade.good, at: state.dueAt);
      final beforeThird = state;

      state = reviewOn(state, ReviewGrade.good, at: state.dueAt);

      expect(
        state.intervalDays,
        (beforeThird.intervalDays * state.easeFactor).round(),
      );
      expect(state.intervalDays, greaterThan(6));
    });
  });

  group('the ease factor', () {
    test('starts at 2.5', () {
      expect(const SchedulingState().easeFactor, 2.5);
    });

    test('is unchanged by an ordinary success', () {
      final state = reviewOn(const SchedulingState(), ReviewGrade.good);

      expect(state.easeFactor, closeTo(2.5, 0.0001));
    });

    test('rises when the word came instantly', () {
      final state = reviewOn(const SchedulingState(), ReviewGrade.easy);

      expect(state.easeFactor, greaterThan(2.5));
    });

    test('falls when the word was hard', () {
      final state = reviewOn(const SchedulingState(), ReviewGrade.hard);

      expect(state.easeFactor, lessThan(2.5));
    });

    test('never falls below the floor, however often the word is forgotten', () {
      var state = const SchedulingState();
      for (var attempt = 0; attempt < 20; attempt++) {
        state = reviewOn(state, ReviewGrade.forgot);
      }

      expect(state.easeFactor, SchedulingState.minimumEaseFactor);
    });
  });

  group('forgetting a word', () {
    test('restarts the ladder', () {
      var state = const SchedulingState();
      for (var attempt = 0; attempt < 4; attempt++) {
        state = reviewOn(state, ReviewGrade.good, at: state.dueAt ?? monday);
      }
      expect(state.repetitionCount, 4);

      state = reviewOn(state, ReviewGrade.forgot, at: state.dueAt);

      expect(state.repetitionCount, 0);
      expect(state.intervalDays, 1);
    });

    test('keeps the reduced ease, so a hard word stays hard', () {
      // The alternative — resetting the ease too — would forget that this word
      // has been failed before, and schedule it as if it were new.
      var state = reviewOn(const SchedulingState(), ReviewGrade.forgot);
      final afterFirstLapse = state.easeFactor;

      state = reviewOn(state, ReviewGrade.forgot);

      expect(state.easeFactor, lessThan(afterFirstLapse));
    });
  });

  group('bounds', () {
    test('a word answered easily forever does not overflow its interval', () {
      var state = const SchedulingState();
      for (var attempt = 0; attempt < 40; attempt++) {
        state = reviewOn(state, ReviewGrade.easy, at: state.dueAt ?? monday);
      }

      expect(state.intervalDays, lessThanOrEqualTo(3650));
      expect(state.dueAt, isNotNull);
    });

    test('an interval is never less than a day', () {
      var state = const SchedulingState(easeFactor: 1.3, intervalDays: 1);
      state = reviewOn(state, ReviewGrade.hard);
      state = reviewOn(state, ReviewGrade.hard, at: state.dueAt);
      state = reviewOn(state, ReviewGrade.hard, at: state.dueAt);

      expect(state.intervalDays, greaterThanOrEqualTo(1));
    });

    test('reviewing stamps the time in UTC', () {
      final state = schedule(
        const SchedulingState(),
        grade: ReviewGrade.good,
        reviewedAt: DateTime(2026, 3, 2, 9),
      );

      expect(state.lastReviewedAt!.isUtc, isTrue);
    });
  });

  group('being due', () {
    test('is true once the due date has passed', () {
      final state = reviewOn(const SchedulingState(), ReviewGrade.good);

      expect(state.isDueAt(monday), isFalse);
      expect(state.isDueAt(monday.add(const Duration(days: 1))), isTrue);
      expect(state.isDueAt(monday.add(const Duration(days: 5))), isTrue);
    });

    test('overdue days count from the due date', () {
      final state = reviewOn(const SchedulingState(), ReviewGrade.good);

      expect(state.overdueDaysAt(monday.add(const Duration(days: 4))), 3);
    });
  });

  group('review priority', () {
    double priorityOf(
      SchedulingState state, {
      bool isFlagged = false,
      DateTime? now,
    }) {
      return reviewPriority(
        state: state,
        isFlagged: isFlagged,
        now: now ?? monday,
      );
    }

    test('a word the user flagged outranks everything else', () {
      final flagged = priorityOf(const SchedulingState(), isFlagged: true);
      final veryOverdue = priorityOf(
        SchedulingState(
          dueAt: monday.subtract(const Duration(days: 3000)),
          easeFactor: 1.3,
        ),
      );

      expect(flagged, greaterThan(veryOverdue));
    });

    test('among unflagged words, the most overdue comes first', () {
      final overdueByFive = priorityOf(
        SchedulingState(dueAt: monday.subtract(const Duration(days: 5))),
      );
      final overdueByOne = priorityOf(
        SchedulingState(dueAt: monday.subtract(const Duration(days: 1))),
      );

      expect(overdueByFive, greaterThan(overdueByOne));
    });

    test('a low ease factor breaks a tie between equally overdue words', () {
      final struggling = priorityOf(
        SchedulingState(
          dueAt: monday.subtract(const Duration(days: 2)),
          easeFactor: 1.4,
        ),
      );
      final comfortable = priorityOf(
        SchedulingState(
          dueAt: monday.subtract(const Duration(days: 2)),
          easeFactor: 2.5,
        ),
      );

      expect(struggling, greaterThan(comfortable));
    });

    test('a word not yet due is not pushed up by being early', () {
      final notDue = priorityOf(
        SchedulingState(dueAt: monday.add(const Duration(days: 10))),
      );

      expect(notDue, 0);
    });
  });
}

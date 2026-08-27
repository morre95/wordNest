/// Spaced repetition scheduling: SM-2.
///
/// Pure and free of I/O by design — no database, no clock beyond what is passed
/// in — so every branch can be tested directly. Nothing in this file knows that
/// a glossary exists.
///
/// SM-2 rather than FSRS because FSRS needs a fitted model per user and a
/// review history to fit it against; a new user has neither, and SM-2's
/// behaviour is the same shape for a fraction of the machinery.
library;

import 'package:flutter/foundation.dart';

/// How well the user answered, in the four steps a review screen offers.
///
/// The numbers are SM-2's 0–5 quality scale. Only these four are used: the
/// finer distinctions in the original scale are not ones a person can make
/// reliably about a word they just saw.
enum ReviewGrade {
  /// Did not know it. A lapse: the schedule restarts.
  forgot(1),

  /// Recalled it, but with effort.
  hard(3),

  /// Recalled it.
  good(4),

  /// Recalled it instantly.
  easy(5);

  const ReviewGrade(this.quality);

  /// The SM-2 quality value, 0–5.
  final int quality;

  /// Below 3 is a lapse in SM-2's terms.
  bool get isLapse => quality < 3;
}

/// Everything the scheduler needs to know about an entry.
@immutable
class SchedulingState {
  const SchedulingState({
    this.intervalDays = 0,
    this.easeFactor = startingEaseFactor,
    this.repetitionCount = 0,
    this.lastReviewedAt,
    this.dueAt,
  });

  /// SM-2's starting ease. A word begins neither easy nor hard.
  static const startingEaseFactor = 2.5;

  /// SM-2's floor. Below this the intervals collapse and the word is shown
  /// every day forever, which helps nobody.
  static const minimumEaseFactor = 1.3;

  /// Days between the last review and the next.
  final int intervalDays;

  /// How much the interval grows each time the word is recalled.
  final double easeFactor;

  /// Consecutive successful reviews. Reset to zero by a lapse.
  final int repetitionCount;

  final DateTime? lastReviewedAt;
  final DateTime? dueAt;

  /// An entry never reviewed is due as soon as it exists.
  bool isDueAt(DateTime now) =>
      dueAt == null || !dueAt!.toUtc().isAfter(now.toUtc());

  /// How overdue, in days. Negative when not yet due, zero when never reviewed.
  int overdueDaysAt(DateTime now) {
    if (dueAt == null) return 0;
    return now.toUtc().difference(dueAt!.toUtc()).inDays;
  }

  @override
  bool operator ==(Object other) =>
      other is SchedulingState &&
      other.intervalDays == intervalDays &&
      other.easeFactor == easeFactor &&
      other.repetitionCount == repetitionCount &&
      other.lastReviewedAt == lastReviewedAt &&
      other.dueAt == dueAt;

  @override
  int get hashCode => Object.hash(
        intervalDays,
        easeFactor,
        repetitionCount,
        lastReviewedAt,
        dueAt,
      );

  @override
  String toString() => 'SchedulingState(interval: $intervalDays d, '
      'ease: ${easeFactor.toStringAsFixed(2)}, reps: $repetitionCount)';
}

/// Applies one review to [state] and returns the new schedule.
///
/// [reviewedAt] is passed in rather than read from a clock so the caller — and
/// the tests — decide what "now" is.
SchedulingState schedule(
  SchedulingState state, {
  required ReviewGrade grade,
  required DateTime reviewedAt,
}) {
  final ease = _nextEaseFactor(state.easeFactor, grade);

  if (grade.isLapse) {
    // A lapse restarts the ladder but keeps the ease factor, which has already
    // been reduced. Forgetting a word twice makes it come back sooner both
    // times, rather than resetting to a clean slate and forgetting that it is
    // a hard word.
    return SchedulingState(
      intervalDays: 1,
      easeFactor: ease,
      repetitionCount: 0,
      lastReviewedAt: reviewedAt.toUtc(),
      dueAt: reviewedAt.toUtc().add(const Duration(days: 1)),
    );
  }

  final repetitions = state.repetitionCount + 1;
  final interval = switch (repetitions) {
    1 => 1,
    2 => 6,
    _ => (state.intervalDays * ease).round().clamp(1, _maximumIntervalDays),
  };

  return SchedulingState(
    intervalDays: interval,
    easeFactor: ease,
    repetitionCount: repetitions,
    lastReviewedAt: reviewedAt.toUtc(),
    dueAt: reviewedAt.toUtc().add(Duration(days: interval)),
  );
}

/// Ten years. Past this the schedule is meaningless and the number only risks
/// overflowing something downstream.
const _maximumIntervalDays = 3650;

double _nextEaseFactor(double current, ReviewGrade grade) {
  final quality = grade.quality;
  // SM-2's ease adjustment: unchanged at quality 4, up slightly at 5, down at
  // 3 and sharply below.
  final adjusted =
      current + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
  return adjusted < SchedulingState.minimumEaseFactor
      ? SchedulingState.minimumEaseFactor
      : adjusted;
}

/// How urgently an entry should be reviewed. Higher comes first.
///
/// Three signals, in the order the specification asks for: the user's own "this
/// one is hard" flag outranks everything, then how far past due it is, then how
/// low its ease factor has fallen.
double reviewPriority({
  required SchedulingState state,
  required bool isFlagged,
  required DateTime now,
}) {
  // Large enough that no amount of overdue-ness outranks an explicit flag: a
  // user who says a word is hard has told us something we cannot infer.
  const flagWeight = 10000.0;

  final overdue = state.overdueDaysAt(now).clamp(0, 3650).toDouble();

  // A low ease factor means repeated failure. Scaled so it breaks ties between
  // equally overdue words rather than competing with being overdue at all.
  final difficulty =
      (SchedulingState.startingEaseFactor - state.easeFactor).clamp(0.0, 1.2);

  return (isFlagged ? flagWeight : 0) + overdue + difficulty * 10;
}

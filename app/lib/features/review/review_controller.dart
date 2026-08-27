import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/review_repository.dart';
import '../../core/providers.dart';
import '../../core/review/scheduler.dart';

/// Where a review session has got to.
@immutable
class ReviewSession {
  const ReviewSession({
    this.cards = const [],
    this.position = 0,
    this.isAnswerVisible = false,
    this.isLoading = true,
    this.reviewed = 0,
  });

  final List<ReviewCard> cards;
  final int position;

  /// The translation is hidden until the user has tried to recall it —
  /// otherwise there is nothing to grade.
  final bool isAnswerVisible;

  final bool isLoading;

  /// How many were answered this session, for the progress line.
  final int reviewed;

  ReviewCard? get current =>
      position < cards.length ? cards[position] : null;

  bool get isFinished => !isLoading && current == null;

  int get remaining => cards.length - position;

  ReviewSession copyWith({
    List<ReviewCard>? cards,
    int? position,
    bool? isAnswerVisible,
    bool? isLoading,
    int? reviewed,
  }) {
    return ReviewSession(
      cards: cards ?? this.cards,
      position: position ?? this.position,
      isAnswerVisible: isAnswerVisible ?? this.isAnswerVisible,
      isLoading: isLoading ?? this.isLoading,
      reviewed: reviewed ?? this.reviewed,
    );
  }
}

/// Drives one review session: fetch the queue, reveal, grade, advance.
class ReviewController extends Notifier<ReviewSession> {
  ReviewRepository get _reviews => ref.read(reviewRepositoryProvider);

  @override
  ReviewSession build() {
    // Loaded once when the screen opens. Deliberately not a live stream: a
    // queue that reshuffled underneath the user mid-session would be
    // disorienting, and every answer changes what is due.
    Future.microtask(load);
    return const ReviewSession();
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true);
    final cards = await _reviews.dueCards();
    state = ReviewSession(cards: cards, isLoading: false);
  }

  void revealAnswer() => state = state.copyWith(isAnswerVisible: true);

  /// Records the grade and moves on.
  ///
  /// The card is not re-queued even on a lapse: SM-2 schedules it for tomorrow,
  /// and drilling a forgotten word twice in one minute teaches recognition
  /// rather than recall.
  Future<void> grade(ReviewGrade grade) async {
    final card = state.current;
    if (card == null) return;

    await _reviews.recordReview(card.entry, grade: grade);
    state = state.copyWith(
      position: state.position + 1,
      isAnswerVisible: false,
      reviewed: state.reviewed + 1,
    );
  }

  /// Skips without recording anything, so the word stays due.
  void skip() => state = state.copyWith(
        position: state.position + 1,
        isAnswerVisible: false,
      );

  Future<void> setFlagged({required bool isFlagged}) async {
    final card = state.current;
    if (card == null) return;
    await ref
        .read(glossaryRepositoryProvider)
        .setFlagged(card.entry.id, isFlagged: isFlagged);
    final updated = [...state.cards];
    updated[state.position] = ReviewCard(
      entry: card.entry.copyWith(isFlagged: isFlagged),
      state: card.state,
      example: card.example,
    );
    state = state.copyWith(cards: updated);
  }
}

final reviewControllerProvider =
    NotifierProvider<ReviewController, ReviewSession>(ReviewController.new);

/// How many words are waiting, for the badge on the glossary screen.
final dueCountProvider = StreamProvider.autoDispose<int>(
  (ref) => ref.watch(reviewRepositoryProvider).watchDueCount(),
);

final statisticsProvider = FutureProvider.autoDispose<GlossaryStatistics>(
  (ref) => ref.watch(reviewRepositoryProvider).statistics(),
);

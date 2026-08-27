/// How two versions of a row become one, on the device.
///
/// Pure: no database, no clock, no network. The same rules exist on the server
/// in `api/src/wordnest_api/features/sync/merge.py`, and the two are kept in
/// step by the same set of named cases.
///
/// Blanket last-write-wins is wrong here, because the three kinds of data merge
/// differently:
///
/// * **Utterances** are immutable once finalised. Only the device that created
///   one ever writes it again, to attach the enriched translation. Two devices
///   cannot disagree about one.
/// * **Review logs** are immutable events. Two devices reviewing offline both
///   contribute; the merge is deduplication by id, nothing more.
/// * **Glossary entries** genuinely merge, field by field, and are the reason
///   this file exists.
library;

import 'package:flutter/foundation.dart';

/// What the merge decided.
enum MergeOutcome {
  /// The row is new here; insert it.
  inserted,

  /// The incoming version won outright.
  replaced,

  /// The stored version won; nothing to write.
  kept,

  /// Fields were taken from both sides.
  merged,
}

@immutable
class MergeResult<T> {
  const MergeResult(this.outcome, this.value);

  final MergeOutcome outcome;
  final T value;

  bool get shouldWrite =>
      outcome == MergeOutcome.inserted ||
      outcome == MergeOutcome.replaced ||
      outcome == MergeOutcome.merged;
}

/// True when [left] is strictly later than [right].
///
/// Strictly, so a tie leaves the stored version in place: an equal timestamp
/// means nothing actually changed, and rewriting it would mark the row dirty
/// again and push it straight back to the server.
bool isLater(DateTime? left, DateTime? right) {
  if (left == null) return false;
  if (right == null) return true;
  return left.toUtc().isAfter(right.toUtc());
}

/// Recomputes when an entry is next due.
///
/// Called after every merge, so a due date can never survive the schedule it
/// was derived from. Without this, a stale date from the losing side could
/// resurface an entry the winning side had already scheduled far out.
DateTime? dueDateFrom({
  required DateTime? lastReviewedAt,
  required int intervalDays,
}) {
  if (lastReviewedAt == null) return null;
  return lastReviewedAt.toUtc().add(Duration(days: intervalDays.clamp(0, 36500)));
}

// --- Utterances -------------------------------------------------------------

@immutable
class UtteranceSnapshot {
  const UtteranceSnapshot({
    required this.id,
    required this.updatedAt,
    required this.sourceText,
    required this.translationText,
    required this.enrichmentState,
    required this.isFlagged,
    this.literalGloss,
    this.deletedAt,
  });

  final String id;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final String sourceText;
  final String translationText;
  final String? literalGloss;
  final String enrichmentState;
  final bool isFlagged;

  @override
  bool operator ==(Object other) =>
      other is UtteranceSnapshot &&
      other.id == id &&
      other.updatedAt == updatedAt &&
      other.deletedAt == deletedAt &&
      other.sourceText == sourceText &&
      other.translationText == translationText &&
      other.literalGloss == literalGloss &&
      other.enrichmentState == enrichmentState &&
      other.isFlagged == isFlagged;

  @override
  int get hashCode => Object.hash(
        id,
        updatedAt,
        deletedAt,
        sourceText,
        translationText,
        literalGloss,
        enrichmentState,
        isFlagged,
      );
}

/// Append-only. A newer version replaces an older one; anything else is kept.
///
/// There is no ownership check here, unlike on the server: a row arriving from
/// the server has already passed it.
MergeResult<UtteranceSnapshot> mergeUtterance({
  required UtteranceSnapshot? local,
  required UtteranceSnapshot remote,
}) {
  if (local == null) return MergeResult(MergeOutcome.inserted, remote);
  if (!isLater(remote.updatedAt, local.updatedAt)) {
    return MergeResult(MergeOutcome.kept, local);
  }
  return MergeResult(MergeOutcome.replaced, remote);
}

// --- Review logs ------------------------------------------------------------

@immutable
class ReviewLogSnapshot {
  const ReviewLogSnapshot({
    required this.id,
    required this.glossaryEntryId,
    required this.reviewedAt,
    required this.grade,
    required this.scheduledIntervalDays,
    required this.scheduledEaseFactor,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String glossaryEntryId;
  final DateTime reviewedAt;
  final int grade;
  final int scheduledIntervalDays;
  final double scheduledEaseFactor;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// Deduplication, and nothing else. A review happened or it did not.
MergeResult<ReviewLogSnapshot> mergeReviewLog({
  required ReviewLogSnapshot? local,
  required ReviewLogSnapshot remote,
}) {
  if (local == null) return MergeResult(MergeOutcome.inserted, remote);
  return MergeResult(MergeOutcome.kept, local);
}

// --- Glossary entries -------------------------------------------------------

@immutable
class GlossaryEntrySnapshot {
  const GlossaryEntrySnapshot({
    required this.id,
    required this.lemma,
    required this.surfaceForm,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.seenCount,
    required this.isFlagged,
    required this.intervalDays,
    required this.easeFactor,
    required this.repetitionCount,
    required this.updatedAt,
    this.partOfSpeech,
    this.targetForm,
    this.exampleUtteranceId,
    this.dueAt,
    this.lastReviewedAt,
    this.deletedAt,
  });

  final String id;
  final String lemma;
  final String surfaceForm;
  final String? partOfSpeech;
  final String? targetForm;
  final String sourceLanguage;
  final String targetLanguage;
  final int seenCount;
  final String? exampleUtteranceId;
  final bool isFlagged;
  final int intervalDays;
  final double easeFactor;
  final int repetitionCount;
  final DateTime? dueAt;
  final DateTime? lastReviewedAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  GlossaryEntrySnapshot copyWith({
    String? lemma,
    String? surfaceForm,
    Object? partOfSpeech = _unset,
    Object? targetForm = _unset,
    int? seenCount,
    Object? exampleUtteranceId = _unset,
    bool? isFlagged,
    int? intervalDays,
    double? easeFactor,
    int? repetitionCount,
    Object? dueAt = _unset,
    Object? lastReviewedAt = _unset,
    DateTime? updatedAt,
    Object? deletedAt = _unset,
  }) {
    return GlossaryEntrySnapshot(
      id: id,
      lemma: lemma ?? this.lemma,
      surfaceForm: surfaceForm ?? this.surfaceForm,
      partOfSpeech: partOfSpeech == _unset
          ? this.partOfSpeech
          : partOfSpeech as String?,
      targetForm:
          targetForm == _unset ? this.targetForm : targetForm as String?,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      seenCount: seenCount ?? this.seenCount,
      exampleUtteranceId: exampleUtteranceId == _unset
          ? this.exampleUtteranceId
          : exampleUtteranceId as String?,
      isFlagged: isFlagged ?? this.isFlagged,
      intervalDays: intervalDays ?? this.intervalDays,
      easeFactor: easeFactor ?? this.easeFactor,
      repetitionCount: repetitionCount ?? this.repetitionCount,
      dueAt: dueAt == _unset ? this.dueAt : dueAt as DateTime?,
      lastReviewedAt: lastReviewedAt == _unset
          ? this.lastReviewedAt
          : lastReviewedAt as DateTime?,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt == _unset ? this.deletedAt : deletedAt as DateTime?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlossaryEntrySnapshot &&
      other.id == id &&
      other.lemma == lemma &&
      other.surfaceForm == surfaceForm &&
      other.partOfSpeech == partOfSpeech &&
      other.targetForm == targetForm &&
      other.sourceLanguage == sourceLanguage &&
      other.targetLanguage == targetLanguage &&
      other.seenCount == seenCount &&
      other.exampleUtteranceId == exampleUtteranceId &&
      other.isFlagged == isFlagged &&
      other.intervalDays == intervalDays &&
      other.easeFactor == easeFactor &&
      other.repetitionCount == repetitionCount &&
      other.dueAt == dueAt &&
      other.lastReviewedAt == lastReviewedAt &&
      other.updatedAt == updatedAt &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hashAll([
        id,
        lemma,
        surfaceForm,
        partOfSpeech,
        targetForm,
        sourceLanguage,
        targetLanguage,
        seenCount,
        exampleUtteranceId,
        isFlagged,
        intervalDays,
        easeFactor,
        repetitionCount,
        dueAt,
        lastReviewedAt,
        updatedAt,
        deletedAt,
      ]);
}

const _unset = Object();

/// Field-level merge, because the fields do not agree on one rule.
///
/// * [GlossaryEntrySnapshot.seenCount] is not merged at all — it is recomputed
///   from the occurrence rows afterwards, so two devices that each heard the
///   word twice converge on four instead of on whichever number arrived last.
/// * [GlossaryEntrySnapshot.isFlagged] is the user's own signal: last-write-wins
///   on `updatedAt`.
/// * The scheduling state moves as one block, decided by `lastReviewedAt` — the
///   side that actually reviewed most recently knows best. Splitting the block
///   field by field would produce a schedule neither device ever had.
/// * [GlossaryEntrySnapshot.dueAt] is then recomputed from the winning state.
/// * The description (lemma, part of speech, target form) comes from backend
///   enrichment, so last-write-wins is right.
/// * A deletion is another field under last-write-wins, so a deletion racing an
///   update is settled by which happened later.
MergeResult<GlossaryEntrySnapshot> mergeGlossaryEntry({
  required GlossaryEntrySnapshot? local,
  required GlossaryEntrySnapshot remote,
}) {
  if (local == null) {
    return MergeResult(
      MergeOutcome.inserted,
      remote.copyWith(
        dueAt: dueDateFrom(
          lastReviewedAt: remote.lastReviewedAt,
          intervalDays: remote.intervalDays,
        ),
      ),
    );
  }

  final remoteIsNewer = isLater(remote.updatedAt, local.updatedAt);
  final describedBy = remoteIsNewer ? remote : local;
  final reviewedBy =
      isLater(remote.lastReviewedAt, local.lastReviewedAt) ? remote : local;

  var merged = local.copyWith(
    lemma: describedBy.lemma,
    surfaceForm: describedBy.surfaceForm,
    partOfSpeech: describedBy.partOfSpeech,
    targetForm: describedBy.targetForm,
    exampleUtteranceId: describedBy.exampleUtteranceId,
    isFlagged: describedBy.isFlagged,
    deletedAt: describedBy.deletedAt,
    intervalDays: reviewedBy.intervalDays,
    easeFactor: reviewedBy.easeFactor,
    repetitionCount: reviewedBy.repetitionCount,
    lastReviewedAt: reviewedBy.lastReviewedAt,
    updatedAt: remoteIsNewer ? remote.updatedAt : local.updatedAt,
  );
  merged = merged.copyWith(
    dueAt: dueDateFrom(
      lastReviewedAt: merged.lastReviewedAt,
      intervalDays: merged.intervalDays,
    ),
  );

  if (merged == local) return MergeResult(MergeOutcome.kept, local);
  if (identical(describedBy, remote) && identical(reviewedBy, remote)) {
    return MergeResult(MergeOutcome.replaced, merged);
  }
  return MergeResult(MergeOutcome.merged, merged);
}

// --- Occurrences ------------------------------------------------------------

@immutable
class GlossaryOccurrenceSnapshot {
  const GlossaryOccurrenceSnapshot({
    required this.id,
    required this.glossaryEntryId,
    required this.utteranceId,
    required this.surfaceForm,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String glossaryEntryId;
  final String utteranceId;
  final String surfaceForm;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// An occurrence is a fact: this word was in this sentence.
///
/// Immutable except for two things that can change — a tombstone, when
/// enrichment merges two entries, and the entry it points at, when a lemma is
/// re-keyed. Both follow `updatedAt`.
MergeResult<GlossaryOccurrenceSnapshot> mergeGlossaryOccurrence({
  required GlossaryOccurrenceSnapshot? local,
  required GlossaryOccurrenceSnapshot remote,
}) {
  if (local == null) return MergeResult(MergeOutcome.inserted, remote);
  if (!isLater(remote.updatedAt, local.updatedAt)) {
    return MergeResult(MergeOutcome.kept, local);
  }
  return MergeResult(MergeOutcome.replaced, remote);
}

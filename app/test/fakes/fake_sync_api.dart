import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/network/api_exception.dart';
import 'package:wordnest/core/sync/merge.dart';
import 'package:wordnest/core/sync/sync_api.dart';

/// A [SyncApi] that behaves like the real server without one.
///
/// It holds rows in memory, hands out monotonic sequence numbers, and applies
/// the same merge rules — so two [SyncEngine]s pointed at one instance are a
/// faithful simulation of two devices sharing an account.
class FakeSyncApi implements SyncApi {
  FakeSyncApi({this.pageSize = 100});

  final int pageSize;

  /// When set, [sync] throws this instead of answering.
  ApiException? failure;

  int _sequence = 0;
  int syncCalls = 0;

  final _utterances = <String, ({int sequence, UtteranceSnapshot row, Map<String, Object?> extras})>{};
  final _entries = <String, ({int sequence, GlossaryEntrySnapshot row})>{};
  final _occurrences =
      <String, ({int sequence, GlossaryOccurrenceSnapshot row})>{};
  final _reviews = <String, ({int sequence, ReviewLogSnapshot row})>{};

  /// Which device pushed each utterance, so ownership can be enforced as the
  /// real server enforces it.
  final _utteranceOwners = <String, String>{};

  /// Set by a test to pretend the push came from a particular device.
  String deviceId = 'device-a';

  @override
  Future<SyncPage> sync({
    required int cursor,
    required List<Utterance> utterances,
    required List<GlossaryEntry> entries,
    required List<GlossaryOccurrence> occurrences,
    required List<ReviewLog> reviews,
  }) async {
    syncCalls++;
    if (failure != null) throw failure!;

    final rejected = <({String id, String table, String code})>[];

    for (final row in utterances) {
      final owner = _utteranceOwners[row.id];
      if (owner != null && owner != deviceId) {
        rejected.add((id: row.id, table: 'utterances', code: 'NOT_YOUR_UTTERANCE'));
        continue;
      }
      final incoming = UtteranceSnapshot(
        id: row.id,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
        sourceText: row.sourceText,
        translationText: row.translationText,
        literalGloss: row.literalGloss,
        enrichmentState: row.enrichmentState.name,
        isFlagged: row.isFlagged,
      );
      final result = mergeUtterance(
        local: _utterances[row.id]?.row,
        remote: incoming,
      );
      if (!result.shouldWrite) continue;
      _utteranceOwners[row.id] = deviceId;
      _utterances[row.id] = (
        sequence: ++_sequence,
        row: result.value,
        extras: {
          'source_language': row.sourceLanguage,
          'target_language': row.targetLanguage,
          'spoken_at': row.spokenAt,
        },
      );
    }

    for (final row in entries) {
      final incoming = GlossaryEntrySnapshot(
        id: row.id,
        lemma: row.lemma,
        surfaceForm: row.surfaceForm,
        partOfSpeech: row.partOfSpeech,
        targetForm: row.targetForm,
        sourceLanguage: row.sourceLanguage,
        targetLanguage: row.targetLanguage,
        seenCount: row.seenCount,
        exampleUtteranceId: row.exampleUtteranceId,
        isFlagged: row.isFlagged,
        intervalDays: row.intervalDays,
        easeFactor: row.easeFactor,
        repetitionCount: row.repetitionCount,
        dueAt: row.dueAt,
        lastReviewedAt: row.lastReviewedAt,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );
      // The word is the real key, as on the server: two devices that learned it
      // offline each generated their own id.
      final existingId = _entries.entries
          .where((held) =>
              held.value.row.lemma == row.lemma &&
              held.value.row.sourceLanguage == row.sourceLanguage &&
              held.value.row.targetLanguage == row.targetLanguage)
          .map((held) => held.key)
          .firstOrNull;
      final key = existingId ?? row.id;
      final result = mergeGlossaryEntry(
        local: _entries[key]?.row,
        remote: incoming,
      );
      if (!result.shouldWrite) continue;
      _entries[key] = (sequence: ++_sequence, row: result.value);
    }

    for (final row in occurrences) {
      final incoming = GlossaryOccurrenceSnapshot(
        id: row.id,
        glossaryEntryId: row.glossaryEntryId,
        utteranceId: row.utteranceId,
        surfaceForm: row.surfaceForm,
        updatedAt: row.updatedAt,
        deletedAt: row.deletedAt,
      );
      final result = mergeGlossaryOccurrence(
        local: _occurrences[row.id]?.row,
        remote: incoming,
      );
      if (!result.shouldWrite) continue;
      _occurrences[row.id] = (sequence: ++_sequence, row: result.value);
    }

    for (final row in reviews) {
      if (_reviews.containsKey(row.id)) continue;
      _reviews[row.id] = (
        sequence: ++_sequence,
        row: ReviewLogSnapshot(
          id: row.id,
          glossaryEntryId: row.glossaryEntryId,
          reviewedAt: row.reviewedAt,
          grade: row.grade,
          scheduledIntervalDays: row.scheduledIntervalDays,
          scheduledEaseFactor: row.scheduledEaseFactor,
          updatedAt: row.updatedAt,
          deletedAt: row.deletedAt,
        ),
      );
    }

    // --- Pull, oldest first, one page ---
    var highest = cursor;
    var remaining = pageSize;

    List<T> take<T>(
      Iterable<({int sequence, T row})> held,
    ) {
      final page = held.where((entry) => entry.sequence > cursor).toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      final taken = page.take(remaining).toList();
      remaining -= taken.length;
      for (final entry in taken) {
        if (entry.sequence > highest) highest = entry.sequence;
      }
      return taken.map((entry) => entry.row).toList();
    }

    final pulledUtterances = _utterances.values
        .where((entry) => entry.sequence > cursor)
        .toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    final utterancePage = pulledUtterances.take(remaining).toList();
    remaining -= utterancePage.length;
    for (final entry in utterancePage) {
      if (entry.sequence > highest) highest = entry.sequence;
    }

    final entryPage = take(_entries.values);
    final occurrencePage = take(_occurrences.values);
    final reviewPage = take(_reviews.values);

    final hasMore = [
      ..._utterances.values.map((entry) => entry.sequence),
      ..._entries.values.map((entry) => entry.sequence),
      ..._occurrences.values.map((entry) => entry.sequence),
      ..._reviews.values.map((entry) => entry.sequence),
    ].any((sequence) => sequence > highest);

    return SyncPage(
      cursor: highest,
      hasMore: hasMore,
      applied: utterances.length + entries.length + occurrences.length +
          reviews.length -
          rejected.length,
      utterances: utterancePage.map((entry) => entry.row).toList(),
      utteranceExtras: utterancePage.map((entry) => entry.extras).toList(),
      entries: entryPage,
      occurrences: occurrencePage,
      reviews: reviewPage,
      rejected: rejected,
    );
  }

  int get rowCount =>
      _utterances.length +
      _entries.length +
      _occurrences.length +
      _reviews.length;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

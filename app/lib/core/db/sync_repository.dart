import 'package:drift/drift.dart';

import '../clock.dart';
import '../sync/merge.dart';
import 'database.dart';
import 'tables.dart';

/// Where sync got to on this device.
class SyncState {
  const SyncState({
    required this.cursor,
    this.lastSyncedAt,
    this.lastError,
  });

  final int cursor;
  final DateTime? lastSyncedAt;
  final String? lastError;
}

/// The database side of sync: what to push, and how to apply what comes back.
///
/// The merge decisions themselves live in `core/sync/merge.dart` and are pure.
/// This class only reads, writes, and asks.
class SyncRepository {
  SyncRepository({required WordNestDatabase database, Clock clock = systemClock})
      : _db = database,
        _now = clock;

  final WordNestDatabase _db;
  final Clock _now;

  // --- Cursor -------------------------------------------------------------

  Future<SyncState> readState() async {
    final row = await (_db.select(_db.syncStates)
          ..where((state) => state.id.equals(1)))
        .getSingleOrNull();
    return SyncState(
      cursor: row?.cursor ?? 0,
      lastSyncedAt: row?.lastSyncedAt,
      lastError: row?.lastError,
    );
  }

  Stream<SyncState> watchState() {
    return (_db.select(_db.syncStates)..where((state) => state.id.equals(1)))
        .watchSingleOrNull()
        .map(
          (row) => SyncState(
            cursor: row?.cursor ?? 0,
            lastSyncedAt: row?.lastSyncedAt,
            lastError: row?.lastError,
          ),
        );
  }

  Future<void> recordSuccess(int cursor) async {
    await (_db.update(_db.syncStates)..where((state) => state.id.equals(1)))
        .write(
      SyncStatesCompanion(
        cursor: Value(cursor),
        lastSyncedAt: Value(_now()),
        lastError: const Value(null),
      ),
    );
  }

  Future<void> recordFailure(String reason) async {
    await (_db.update(_db.syncStates)..where((state) => state.id.equals(1)))
        .write(SyncStatesCompanion(lastError: Value(reason)));
  }

  // --- Push ---------------------------------------------------------------

  /// Rows changed here that the server has not acknowledged.
  ///
  /// Capped per table so a device coming back after a fortnight sends several
  /// modest batches rather than one enormous request that times out.
  Future<({
    List<Utterance> utterances,
    List<GlossaryEntry> entries,
    List<GlossaryOccurrence> occurrences,
    List<ReviewLog> reviews,
  })> pendingChanges({int limit = 100}) async {
    Future<List<T>> dirty<T extends DataClass, R extends Table>(
      TableInfo<R, T> table,
      GeneratedColumn<bool> dirtyColumn,
      GeneratedColumn<String> idColumn,
    ) async {
      final query = _db.select(table)
        ..where((_) => dirtyColumn.equals(true))
        // UUIDv7 sorts chronologically, so this is oldest-first without a
        // separate index on a timestamp.
        ..orderBy([(_) => OrderingTerm.asc(idColumn)])
        ..limit(limit);
      return query.get();
    }

    return (
      utterances: await dirty(
        _db.utterances,
        _db.utterances.dirty,
        _db.utterances.id,
      ),
      entries: await dirty(
        _db.glossaryEntries,
        _db.glossaryEntries.dirty,
        _db.glossaryEntries.id,
      ),
      occurrences: await dirty(
        _db.glossaryOccurrences,
        _db.glossaryOccurrences.dirty,
        _db.glossaryOccurrences.id,
      ),
      reviews: await dirty(
        _db.reviewLogs,
        _db.reviewLogs.dirty,
        _db.reviewLogs.id,
      ),
    );
  }

  /// Clears the dirty flag on rows the server accepted.
  ///
  /// Only where `updated_at` still matches what was sent: a row edited while
  /// the request was in flight must stay dirty and go again.
  Future<void> markPushed({
    required Map<String, DateTime> utterances,
    required Map<String, DateTime> entries,
    required Map<String, DateTime> occurrences,
    required Map<String, DateTime> reviews,
  }) async {
    await _db.transaction(() async {
      for (final entry in utterances.entries) {
        await (_db.update(_db.utterances)
              ..where((row) =>
                  row.id.equals(entry.key) &
                  row.updatedAt.equals(entry.value)))
            .write(const UtterancesCompanion(dirty: Value(false)));
      }
      for (final entry in entries.entries) {
        await (_db.update(_db.glossaryEntries)
              ..where((row) =>
                  row.id.equals(entry.key) &
                  row.updatedAt.equals(entry.value)))
            .write(const GlossaryEntriesCompanion(dirty: Value(false)));
      }
      for (final entry in occurrences.entries) {
        await (_db.update(_db.glossaryOccurrences)
              ..where((row) =>
                  row.id.equals(entry.key) &
                  row.updatedAt.equals(entry.value)))
            .write(const GlossaryOccurrencesCompanion(dirty: Value(false)));
      }
      for (final entry in reviews.entries) {
        await (_db.update(_db.reviewLogs)
              ..where((row) =>
                  row.id.equals(entry.key) &
                  row.updatedAt.equals(entry.value)))
            .write(const ReviewLogsCompanion(dirty: Value(false)));
      }
    });
  }

  // --- Pull ---------------------------------------------------------------

  /// Applies rows from the server through the merge rules.
  ///
  /// Everything written here is marked clean: it came from the server, so
  /// pushing it straight back would be a loop.
  Future<int> applyRemote({
    required List<UtteranceSnapshot> utterances,
    required List<Map<String, Object?>> utteranceExtras,
    required List<GlossaryEntrySnapshot> entries,
    required List<GlossaryOccurrenceSnapshot> occurrences,
    required List<ReviewLogSnapshot> reviews,
  }) async {
    var applied = 0;

    await _db.transaction(() async {
      for (var index = 0; index < utterances.length; index++) {
        if (await _applyUtterance(utterances[index], utteranceExtras[index])) {
          applied++;
        }
      }
      for (final entry in entries) {
        if (await _applyEntry(entry)) applied++;
      }
      for (final occurrence in occurrences) {
        if (await _applyOccurrence(occurrence)) applied++;
      }
      for (final review in reviews) {
        if (await _applyReview(review)) applied++;
      }

      // Counts are derived, so they are recomputed once the rows they are
      // derived from have all landed.
      final touched = {
        ...entries.map((entry) => entry.id),
        ...occurrences.map((occurrence) => occurrence.glossaryEntryId),
      };
      for (final entryId in touched) {
        await _recomputeSeenCount(entryId);
      }
    });

    return applied;
  }

  Future<bool> _applyUtterance(
    UtteranceSnapshot remote,
    Map<String, Object?> extras,
  ) async {
    final stored = await (_db.select(_db.utterances)
          ..where((row) => row.id.equals(remote.id)))
        .getSingleOrNull();

    final result = mergeUtterance(
      local: stored == null ? null : _utteranceSnapshot(stored),
      remote: remote,
    );
    if (!result.shouldWrite) return false;

    await _db.into(_db.utterances).insertOnConflictUpdate(
          UtterancesCompanion.insert(
            id: remote.id,
            sourceText: result.value.sourceText,
            translationText: result.value.translationText,
            literalGloss: Value(result.value.literalGloss),
            sourceLanguage: extras['source_language']! as String,
            targetLanguage: extras['target_language']! as String,
            spokenAt: extras['spoken_at']! as DateTime,
            enrichmentState: Value(
              EnrichmentState.values.firstWhere(
                (state) => state.name == result.value.enrichmentState,
                orElse: () => EnrichmentState.pending,
              ),
            ),
            isFlagged: Value(result.value.isFlagged),
            updatedAt: result.value.updatedAt,
            deletedAt: Value(result.value.deletedAt),
            dirty: const Value(false),
          ),
        );
    return true;
  }

  Future<bool> _applyEntry(GlossaryEntrySnapshot remote) async {
    // The row may be held here under a different id: two devices that learned
    // the same word offline each generated one. The word is the real key.
    final stored = await (_db.select(_db.glossaryEntries)
              ..where((row) => row.id.equals(remote.id)))
            .getSingleOrNull() ??
        await (_db.select(_db.glossaryEntries)
              ..where((row) =>
                  row.lemma.equals(remote.lemma) &
                  row.sourceLanguage.equals(remote.sourceLanguage) &
                  row.targetLanguage.equals(remote.targetLanguage)))
            .getSingleOrNull();

    final result = mergeGlossaryEntry(
      local: stored == null ? null : _entrySnapshot(stored),
      remote: remote,
    );
    if (!result.shouldWrite) return false;
    final merged = result.value;

    await _db.into(_db.glossaryEntries).insertOnConflictUpdate(
          GlossaryEntriesCompanion.insert(
            id: stored?.id ?? remote.id,
            lemma: merged.lemma,
            surfaceForm: merged.surfaceForm,
            partOfSpeech: Value(merged.partOfSpeech),
            targetForm: Value(merged.targetForm),
            sourceLanguage: merged.sourceLanguage,
            targetLanguage: merged.targetLanguage,
            exampleUtteranceId: Value(merged.exampleUtteranceId),
            isFlagged: Value(merged.isFlagged),
            intervalDays: Value(merged.intervalDays),
            easeFactor: Value(merged.easeFactor),
            repetitionCount: Value(merged.repetitionCount),
            dueAt: Value(merged.dueAt),
            lastReviewedAt: Value(merged.lastReviewedAt),
            updatedAt: merged.updatedAt,
            deletedAt: Value(merged.deletedAt),
            dirty: const Value(false),
          ),
        );
    return true;
  }

  Future<bool> _applyOccurrence(GlossaryOccurrenceSnapshot remote) async {
    final stored = await (_db.select(_db.glossaryOccurrences)
          ..where((row) => row.id.equals(remote.id)))
        .getSingleOrNull();

    final result = mergeGlossaryOccurrence(
      local: stored == null ? null : _occurrenceSnapshot(stored),
      remote: remote,
    );
    if (!result.shouldWrite) return false;

    // The sentence and the word this points at may not have arrived yet — a
    // page boundary can fall between them. Skip rather than violate the
    // foreign key; the next sync brings it once its parents are here.
    final hasParents = await _hasParents(
      utteranceId: result.value.utteranceId,
      entryId: result.value.glossaryEntryId,
    );
    if (!hasParents) return false;

    await _db.into(_db.glossaryOccurrences).insertOnConflictUpdate(
          GlossaryOccurrencesCompanion.insert(
            id: remote.id,
            glossaryEntryId: result.value.glossaryEntryId,
            utteranceId: result.value.utteranceId,
            surfaceForm: result.value.surfaceForm,
            updatedAt: result.value.updatedAt,
            deletedAt: Value(result.value.deletedAt),
            dirty: const Value(false),
          ),
        );
    return true;
  }

  Future<bool> _applyReview(ReviewLogSnapshot remote) async {
    final stored = await (_db.select(_db.reviewLogs)
          ..where((row) => row.id.equals(remote.id)))
        .getSingleOrNull();
    if (stored != null) return false;

    final entryExists = await (_db.select(_db.glossaryEntries)
          ..where((row) => row.id.equals(remote.glossaryEntryId)))
        .getSingleOrNull();
    if (entryExists == null) return false;

    await _db.into(_db.reviewLogs).insert(
          ReviewLogsCompanion.insert(
            id: remote.id,
            glossaryEntryId: remote.glossaryEntryId,
            reviewedAt: remote.reviewedAt,
            grade: remote.grade,
            scheduledIntervalDays: remote.scheduledIntervalDays,
            scheduledEaseFactor: remote.scheduledEaseFactor,
            updatedAt: remote.updatedAt,
            deletedAt: Value(remote.deletedAt),
            dirty: const Value(false),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return true;
  }

  Future<bool> _hasParents({
    required String utteranceId,
    required String entryId,
  }) async {
    final utterance = await (_db.select(_db.utterances)
          ..where((row) => row.id.equals(utteranceId)))
        .getSingleOrNull();
    if (utterance == null) return false;
    final entry = await (_db.select(_db.glossaryEntries)
          ..where((row) => row.id.equals(entryId)))
        .getSingleOrNull();
    return entry != null;
  }

  Future<void> _recomputeSeenCount(String entryId) async {
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

  // --- Snapshots ----------------------------------------------------------

  static UtteranceSnapshot _utteranceSnapshot(Utterance row) {
    return UtteranceSnapshot(
      id: row.id,
      updatedAt: row.updatedAt,
      deletedAt: row.deletedAt,
      sourceText: row.sourceText,
      translationText: row.translationText,
      literalGloss: row.literalGloss,
      enrichmentState: row.enrichmentState.name,
      isFlagged: row.isFlagged,
    );
  }

  static GlossaryEntrySnapshot _entrySnapshot(GlossaryEntry row) {
    return GlossaryEntrySnapshot(
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
  }

  static GlossaryOccurrenceSnapshot _occurrenceSnapshot(
    GlossaryOccurrence row,
  ) {
    return GlossaryOccurrenceSnapshot(
      id: row.id,
      glossaryEntryId: row.glossaryEntryId,
      utteranceId: row.utteranceId,
      surfaceForm: row.surfaceForm,
      updatedAt: row.updatedAt,
      deletedAt: row.deletedAt,
    );
  }
}

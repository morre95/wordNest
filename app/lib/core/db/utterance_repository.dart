import 'package:drift/drift.dart';

import '../clock.dart';
import '../ids/id_generator.dart';
import '../models/language.dart';
import '../vocabulary/vocabulary_extractor.dart';
import 'database.dart';
import 'glossary_repository.dart';
import 'tables.dart';

/// Writes and reads the record of what the user said.
///
/// Utterances are immutable once finalised. The only later write is the
/// enrichment the backend returns, and only the device that created the row
/// ever makes it — which is what keeps utterances conflict-free during sync.
class UtteranceRepository {
  UtteranceRepository({
    required WordNestDatabase database,
    required GlossaryRepository glossaryRepository,
    IdGenerator idGenerator = const Uuid7Generator(),
    Clock clock = systemClock,
  })  : _db = database,
        _glossary = glossaryRepository,
        _ids = idGenerator,
        _now = clock;

  final WordNestDatabase _db;
  final GlossaryRepository _glossary;
  final IdGenerator _ids;
  final Clock _now;

  /// Saves a finalised utterance and folds its vocabulary into the glossary,
  /// in one transaction so the glossary can never reference a sentence that
  /// was not written.
  Future<Utterance> saveFinalised({
    required String sourceText,
    required String translationText,
    required LanguagePair pair,
    DateTime? spokenAt,
  }) {
    final now = _now();
    final utterance = UtterancesCompanion.insert(
      id: _ids.newId(),
      sourceText: sourceText,
      translationText: translationText,
      sourceLanguage: pair.source.code,
      targetLanguage: pair.target.code,
      spokenAt: spokenAt ?? now,
      updatedAt: now,
    );

    return _db.transaction(() async {
      final saved = await _db.into(_db.utterances).insertReturning(utterance);
      await _glossary.recordWords(
        extractVocabulary(sourceText, languageCode: pair.source.code),
        utterance: saved,
      );
      return saved;
    });
  }

  /// Applies the backend's richer translation to a row this device created.
  Future<void> applyEnrichment(
    String utteranceId, {
    required String translationText,
    String? literalGloss,
  }) async {
    await (_db.update(_db.utterances)
          ..where((row) => row.id.equals(utteranceId)))
        .write(
      UtterancesCompanion(
        translationText: Value(translationText),
        literalGloss: Value(literalGloss),
        enrichmentState: const Value(EnrichmentState.enriched),
        updatedAt: Value(_now()),
        dirty: const Value(true),
      ),
    );
  }

  /// Marks an utterance the backend could not enrich, so the queue does not
  /// retry it forever and the on-device translation stands.
  Future<void> markEnrichmentFailed(String utteranceId) async {
    await (_db.update(_db.utterances)
          ..where((row) => row.id.equals(utteranceId)))
        .write(
      UtterancesCompanion(
        enrichmentState: const Value(EnrichmentState.failed),
        updatedAt: Value(_now()),
        dirty: const Value(true),
      ),
    );
  }

  Future<Utterance?> byId(String id) =>
      (_db.select(_db.utterances)..where((row) => row.id.equals(id)))
          .getSingleOrNull();

  /// Most recent first, tombstones excluded.
  Stream<List<Utterance>> watchRecent({int limit = 50}) {
    return (_db.select(_db.utterances)
          ..where((row) => row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm.desc(row.spokenAt)])
          ..limit(limit))
        .watch();
  }

  /// Utterances still waiting for the backend, oldest first so the queue
  /// drains in the order the user spoke.
  Future<List<Utterance>> pendingEnrichment({int limit = 50}) {
    return (_db.select(_db.utterances)
          ..where((row) =>
              row.deletedAt.isNull() &
              row.enrichmentState.equalsValue(EnrichmentState.pending))
          ..orderBy([(row) => OrderingTerm.asc(row.spokenAt)])
          ..limit(limit))
        .get();
  }

  /// Tombstones rather than deletes, so the deletion reaches other devices.
  Future<void> delete(String id) async {
    final now = _now();
    await (_db.update(_db.utterances)..where((row) => row.id.equals(id)))
        .write(
      UtterancesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  Future<void> setFlagged(String id, {required bool isFlagged}) async {
    await (_db.update(_db.utterances)..where((row) => row.id.equals(id)))
        .write(
      UtterancesCompanion(
        isFlagged: Value(isFlagged),
        updatedAt: Value(_now()),
        dirty: const Value(true),
      ),
    );
  }
}

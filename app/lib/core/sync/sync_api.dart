import '../db/database.dart';
import '../network/api_client.dart';
import '../network/timestamps.dart';
import 'merge.dart';

/// Everything one sync round trip returned.
class SyncPage {
  const SyncPage({
    required this.cursor,
    required this.hasMore,
    required this.applied,
    required this.utterances,
    required this.utteranceExtras,
    required this.entries,
    required this.occurrences,
    required this.reviews,
    required this.rejected,
  });

  final int cursor;

  /// True when the server had more than one page. Sync again straight away
  /// rather than waiting for the next trigger.
  final bool hasMore;

  /// How many pushed rows the server actually wrote.
  final int applied;

  final List<UtteranceSnapshot> utterances;

  /// The columns an utterance carries that the merge rules do not touch,
  /// positionally aligned with [utterances].
  final List<Map<String, Object?>> utteranceExtras;

  final List<GlossaryEntrySnapshot> entries;
  final List<GlossaryOccurrenceSnapshot> occurrences;
  final List<ReviewLogSnapshot> reviews;

  /// Rows the server refused, with a reason. Reported rather than fatal: one
  /// bad row must not stop a fortnight of good ones from landing.
  final List<({String id, String table, String code})> rejected;
}

/// The delta-sync endpoint.
abstract interface class SyncApi {
  Future<SyncPage> sync({
    required int cursor,
    required List<Utterance> utterances,
    required List<GlossaryEntry> entries,
    required List<GlossaryOccurrence> occurrences,
    required List<ReviewLog> reviews,
  });
}

class HttpSyncApi implements SyncApi {
  const HttpSyncApi(this._client);

  final ApiClient _client;

  @override
  Future<SyncPage> sync({
    required int cursor,
    required List<Utterance> utterances,
    required List<GlossaryEntry> entries,
    required List<GlossaryOccurrence> occurrences,
    required List<ReviewLog> reviews,
  }) async {
    final data = await _client.post(
      '/sync',
      body: {
        'cursor': cursor,
        'changes': {
          'utterances': utterances.map(_utteranceJson).toList(),
          'glossary_entries': entries.map(_entryJson).toList(),
          'glossary_occurrences': occurrences.map(_occurrenceJson).toList(),
          'review_logs': reviews.map(_reviewJson).toList(),
        },
      },
    );

    final changes = data['changes'] as Map<String, dynamic>? ?? const {};
    final incoming =
        (changes['utterances'] as List<dynamic>? ?? const []).cast<Map>();

    return SyncPage(
      cursor: data['cursor']! as int,
      hasMore: data['has_more'] as bool? ?? false,
      applied: data['applied'] as int? ?? 0,
      utterances: incoming.map(_utteranceSnapshot).toList(growable: false),
      utteranceExtras: incoming
          .map(
            (row) => <String, Object?>{
              'source_language': row['source_language'],
              'target_language': row['target_language'],
              'spoken_at': parseServerTimestamp(row['spoken_at'] as String),
            },
          )
          .toList(growable: false),
      entries: (changes['glossary_entries'] as List<dynamic>? ?? const [])
          .cast<Map>()
          .map(_entrySnapshot)
          .toList(growable: false),
      occurrences:
          (changes['glossary_occurrences'] as List<dynamic>? ?? const [])
              .cast<Map>()
              .map(_occurrenceSnapshot)
              .toList(growable: false),
      reviews: (changes['review_logs'] as List<dynamic>? ?? const [])
          .cast<Map>()
          .map(_reviewSnapshot)
          .toList(growable: false),
      rejected: (data['rejected'] as List<dynamic>? ?? const [])
          .cast<Map>()
          .map(
            (row) => (
              id: row['id'] as String,
              table: row['table'] as String,
              code: row['code'] as String,
            ),
          )
          .toList(growable: false),
    );
  }

  // --- Outgoing -----------------------------------------------------------

  static String _iso(DateTime moment) => moment.toUtc().toIso8601String();

  static Map<String, Object?> _utteranceJson(Utterance row) => {
        'id': row.id,
        'updated_at': _iso(row.updatedAt),
        'deleted_at': row.deletedAt == null ? null : _iso(row.deletedAt!),
        'source_text': row.sourceText,
        'translation_text': row.translationText,
        'literal_gloss': row.literalGloss,
        'source_language': row.sourceLanguage,
        'target_language': row.targetLanguage,
        'spoken_at': _iso(row.spokenAt),
        'enrichment_state': row.enrichmentState.name,
        'is_flagged': row.isFlagged,
      };

  static Map<String, Object?> _entryJson(GlossaryEntry row) => {
        'id': row.id,
        'updated_at': _iso(row.updatedAt),
        'deleted_at': row.deletedAt == null ? null : _iso(row.deletedAt!),
        'lemma': row.lemma,
        'surface_form': row.surfaceForm,
        'part_of_speech': row.partOfSpeech,
        'target_form': row.targetForm,
        'source_language': row.sourceLanguage,
        'target_language': row.targetLanguage,
        'seen_count': row.seenCount,
        'example_utterance_id': row.exampleUtteranceId,
        'is_flagged': row.isFlagged,
        'interval_days': row.intervalDays,
        'ease_factor': row.easeFactor,
        'repetition_count': row.repetitionCount,
        'due_at': row.dueAt == null ? null : _iso(row.dueAt!),
        'last_reviewed_at':
            row.lastReviewedAt == null ? null : _iso(row.lastReviewedAt!),
      };

  static Map<String, Object?> _occurrenceJson(GlossaryOccurrence row) => {
        'id': row.id,
        'updated_at': _iso(row.updatedAt),
        'deleted_at': row.deletedAt == null ? null : _iso(row.deletedAt!),
        'glossary_entry_id': row.glossaryEntryId,
        'utterance_id': row.utteranceId,
        'surface_form': row.surfaceForm,
      };

  static Map<String, Object?> _reviewJson(ReviewLog row) => {
        'id': row.id,
        'updated_at': _iso(row.updatedAt),
        'deleted_at': row.deletedAt == null ? null : _iso(row.deletedAt!),
        'glossary_entry_id': row.glossaryEntryId,
        'reviewed_at': _iso(row.reviewedAt),
        'grade': row.grade,
        'scheduled_interval_days': row.scheduledIntervalDays,
        'scheduled_ease_factor': row.scheduledEaseFactor,
      };

  // --- Incoming -----------------------------------------------------------

  static DateTime _date(Object? value) =>
      parseServerTimestamp(value! as String);

  static DateTime? _dateOrNull(Object? value) =>
      parseServerTimestampOrNull(value);

  static UtteranceSnapshot _utteranceSnapshot(Map<dynamic, dynamic> row) {
    return UtteranceSnapshot(
      id: row['id'] as String,
      updatedAt: _date(row['updated_at']),
      deletedAt: _dateOrNull(row['deleted_at']),
      sourceText: row['source_text'] as String,
      translationText: row['translation_text'] as String? ?? '',
      literalGloss: row['literal_gloss'] as String?,
      enrichmentState: row['enrichment_state'] as String? ?? 'pending',
      isFlagged: row['is_flagged'] as bool? ?? false,
    );
  }

  static GlossaryEntrySnapshot _entrySnapshot(Map<dynamic, dynamic> row) {
    return GlossaryEntrySnapshot(
      id: row['id'] as String,
      lemma: row['lemma'] as String,
      surfaceForm: row['surface_form'] as String,
      partOfSpeech: row['part_of_speech'] as String?,
      targetForm: row['target_form'] as String?,
      sourceLanguage: row['source_language'] as String,
      targetLanguage: row['target_language'] as String,
      seenCount: row['seen_count'] as int? ?? 0,
      exampleUtteranceId: row['example_utterance_id'] as String?,
      isFlagged: row['is_flagged'] as bool? ?? false,
      intervalDays: row['interval_days'] as int? ?? 0,
      easeFactor: (row['ease_factor'] as num?)?.toDouble() ?? 2.5,
      repetitionCount: row['repetition_count'] as int? ?? 0,
      dueAt: _dateOrNull(row['due_at']),
      lastReviewedAt: _dateOrNull(row['last_reviewed_at']),
      updatedAt: _date(row['updated_at']),
      deletedAt: _dateOrNull(row['deleted_at']),
    );
  }

  static GlossaryOccurrenceSnapshot _occurrenceSnapshot(
    Map<dynamic, dynamic> row,
  ) {
    return GlossaryOccurrenceSnapshot(
      id: row['id'] as String,
      glossaryEntryId: row['glossary_entry_id'] as String,
      utteranceId: row['utterance_id'] as String,
      surfaceForm: row['surface_form'] as String,
      updatedAt: _date(row['updated_at']),
      deletedAt: _dateOrNull(row['deleted_at']),
    );
  }

  static ReviewLogSnapshot _reviewSnapshot(Map<dynamic, dynamic> row) {
    return ReviewLogSnapshot(
      id: row['id'] as String,
      glossaryEntryId: row['glossary_entry_id'] as String,
      reviewedAt: _date(row['reviewed_at']),
      grade: row['grade'] as int,
      scheduledIntervalDays: row['scheduled_interval_days'] as int? ?? 0,
      scheduledEaseFactor:
          (row['scheduled_ease_factor'] as num?)?.toDouble() ?? 2.5,
      updatedAt: _date(row['updated_at']),
      deletedAt: _dateOrNull(row['deleted_at']),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../db/database.dart';
import '../db/glossary_repository.dart';
import '../db/utterance_repository.dart';
import '../models/language.dart';
import '../network/api_exception.dart';
import '../translation/backend_translator.dart';

/// What happened the last time the queue ran, for the status line.
@immutable
class EnrichmentStatus {
  const EnrichmentStatus({
    this.isRunning = false,
    this.pending = 0,
    this.lastError,
    this.lastCompletedAt,
  });

  final bool isRunning;
  final int pending;

  /// Null when the last run succeeded.
  final ApiFailureKind? lastError;
  final DateTime? lastCompletedAt;

  EnrichmentStatus copyWith({
    bool? isRunning,
    int? pending,
    ApiFailureKind? lastError,
    bool clearError = false,
    DateTime? lastCompletedAt,
  }) {
    return EnrichmentStatus(
      isRunning: isRunning ?? this.isRunning,
      pending: pending ?? this.pending,
      lastError: clearError ? null : lastError ?? this.lastError,
      lastCompletedAt: lastCompletedAt ?? this.lastCompletedAt,
    );
  }
}

/// Replaces on-device translations with the backend's, and fills the glossary
/// with real lemmas and target-language forms.
///
/// Every utterance is saved locally first and enriched afterwards, so the
/// microphone never waits on the network. When the backend is unreachable the
/// rows stay `pending` and the next run picks them up — which is what makes the
/// whole loop work offline.
class EnrichmentService {
  EnrichmentService({
    required BackendTranslator backendTranslator,
    required UtteranceRepository utteranceRepository,
    required GlossaryRepository glossaryRepository,
  })  : _translator = backendTranslator,
        _utterances = utteranceRepository,
        _glossary = glossaryRepository;

  /// A cap per run, so a fortnight offline drains over several runs instead of
  /// firing hundreds of requests at once and being rate-limited for it.
  static const batchSize = 20;

  final BackendTranslator _translator;
  final UtteranceRepository _utterances;
  final GlossaryRepository _glossary;

  final _status = ValueNotifier(const EnrichmentStatus());

  /// Guards against two triggers — a finalised utterance and an app resume —
  /// running the queue at the same time and enriching a row twice.
  Future<void>? _inFlight;

  ValueListenable<EnrichmentStatus> get status => _status;

  /// Enriches one utterance immediately, for the sentence just spoken.
  ///
  /// Never throws: a backend that is down must not disturb the speak screen.
  /// The row stays `pending` and the queue retries it later.
  Future<void> enrichNow(Utterance utterance) async {
    try {
      await _enrich(utterance);
      _status.value = _status.value.copyWith(clearError: true);
    } on ApiException catch (error) {
      _noteFailure(error);
    }
  }

  /// Drains the backlog. Safe to call on every resume and every reconnect.
  Future<void> drainQueue() {
    return _inFlight ??= _drain().whenComplete(() => _inFlight = null);
  }

  Future<void> _drain() async {
    _status.value = _status.value.copyWith(isRunning: true);
    try {
      final pending = await _utterances.pendingEnrichment(limit: batchSize);
      _status.value = _status.value.copyWith(pending: pending.length);

      for (final utterance in pending) {
        try {
          await _enrich(utterance);
        } on ApiException catch (error) {
          if (error.isRetryable) {
            // The backend is down or throttling. Stop the run rather than
            // hammering it; the remaining rows keep their place in the queue.
            _noteFailure(error);
            return;
          }
          // The server will never accept this row — an unsupported pair, or
          // text it refuses. Mark it so the queue stops carrying it.
          await _utterances.markEnrichmentFailed(utterance.id);
        }
      }
      _status.value = _status.value.copyWith(
        clearError: true,
        pending: 0,
        lastCompletedAt: DateTime.now().toUtc(),
      );
    } finally {
      _status.value = _status.value.copyWith(isRunning: false);
    }
  }

  Future<void> _enrich(Utterance utterance) async {
    final pair = LanguagePair.parseKey(
      '${utterance.sourceLanguage}-${utterance.targetLanguage}',
    );
    if (pair == null) {
      await _utterances.markEnrichmentFailed(utterance.id);
      return;
    }

    final enriched = await _translator.translate(
      utterance.sourceText,
      pair: pair,
    );

    await _utterances.applyEnrichment(
      utterance.id,
      translationText: enriched.translation,
      literalGloss: enriched.literalGloss,
    );
    await _glossary.applyEnrichment(utterance, enriched.tokens);
  }

  void _noteFailure(ApiException error) {
    _status.value = _status.value.copyWith(lastError: error.kind);
  }

  void dispose() => _status.dispose();
}

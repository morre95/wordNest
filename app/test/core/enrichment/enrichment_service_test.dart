import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/tables.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/enrichment/enrichment_service.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/network/api_exception.dart';
import 'package:wordnest/core/translation/remote_translation.dart';

import '../../fakes/fake_backend_translator.dart';

void main() {
  late WordNestDatabase db;
  late GlossaryRepository glossary;
  late UtteranceRepository utterances;
  late FakeBackendTranslator backend;
  late EnrichmentService enrichment;
  var now = DateTime.utc(2026, 3, 1, 9);

  const englishToSpanish = LanguagePair(
    source: Language(code: 'en', name: 'English'),
    target: Language(code: 'es', name: 'Spanish'),
  );

  setUp(() {
    now = DateTime.utc(2026, 3, 1, 9);
    db = WordNestDatabase.memory();
    glossary = GlossaryRepository(database: db, clock: () => now);
    utterances = UtteranceRepository(
      database: db,
      glossaryRepository: glossary,
      clock: () => now,
    );
    backend = FakeBackendTranslator();
    enrichment = EnrichmentService(
      backendTranslator: backend,
      utteranceRepository: utterances,
      glossaryRepository: glossary,
    );
  });

  tearDown(() {
    enrichment.dispose();
    return db.close();
  });

  Future<Utterance> say(String sentence) async {
    final saved = await utterances.saveFinalised(
      sourceText: sentence,
      translationText: 'rough translation',
      pair: englishToSpanish,
    );
    now = now.add(const Duration(minutes: 1));
    return saved;
  }

  TranslatedToken token(
    String surface, {
    required String lemma,
    required String target,
    String partOfSpeech = 'NOUN',
    bool isContentWord = true,
  }) {
    return TranslatedToken(
      surfaceForm: surface,
      lemma: lemma,
      partOfSpeech: partOfSpeech,
      targetForm: target,
      isContentWord: isContentWord,
    );
  }

  Future<List<GlossaryEntry>> entries() async {
    final rows = await glossary
        .watchEntries(sort: GlossarySort.alphabetical)
        .first;
    return rows.map((row) => row.entry).toList(growable: false);
  }

  group('enriching one utterance', () {
    test('replaces the on-device translation and marks the row enriched',
        () async {
      final saved = await say('the bakery is closed');
      backend.response = RemoteTranslation(
        sourceText: saved.sourceText,
        sourceLanguage: 'en',
        targetLanguage: 'es',
        translation: 'la panadería está cerrada',
        literalGloss: 'the bakery is closed',
      );

      await enrichment.enrichNow(saved);

      final reloaded = await utterances.byId(saved.id);
      expect(reloaded!.translationText, 'la panadería está cerrada');
      expect(reloaded.literalGloss, 'the bakery is closed');
      expect(reloaded.enrichmentState, EnrichmentState.enriched);
    });

    test('fills in the lemma, part of speech and target form', () async {
      final saved = await say('bakery');
      backend.response = RemoteTranslation(
        sourceText: 'bakery',
        sourceLanguage: 'en',
        targetLanguage: 'es',
        translation: 'panadería',
        tokens: [
          token('bakery', lemma: 'bakery', target: 'panadería'),
        ],
      );

      await enrichment.enrichNow(saved);

      final entry = (await entries()).single;
      expect(entry.lemma, 'bakery');
      expect(entry.partOfSpeech, 'NOUN');
      expect(entry.targetForm, 'panadería');
    });

    test('re-keys an entry the offline extractor guessed wrong', () async {
      final saved = await say('she opens the door');
      backend.response = RemoteTranslation(
        sourceText: saved.sourceText,
        sourceLanguage: 'en',
        targetLanguage: 'es',
        translation: 'ella abre la puerta',
        tokens: [
          token('opens', lemma: 'open', target: 'abrir', partOfSpeech: 'VERB'),
          token('door', lemma: 'door', target: 'puerta'),
        ],
      );

      await enrichment.enrichNow(saved);

      expect((await entries()).map((entry) => entry.lemma), ['door', 'open']);
    });

    test('drops function words the offline extractor kept', () async {
      final saved = await say('kaffe tack');
      backend.response = RemoteTranslation(
        sourceText: saved.sourceText,
        sourceLanguage: 'en',
        targetLanguage: 'es',
        translation: '…',
        tokens: [
          token('kaffe', lemma: 'kaffe', target: 'café'),
          token('tack', lemma: 'tack', target: 'gracias', isContentWord: false),
        ],
      );

      await enrichment.enrichNow(saved);

      expect((await entries()).map((entry) => entry.lemma), ['kaffe']);
    });

    test('merges two spellings of one word into a single entry', () async {
      // "open" is learned first; later "opens" is heard and lemmatises onto it.
      final first = await say('open the door');
      backend.responses['open the door'] = RemoteTranslation(
        sourceText: 'open the door',
        sourceLanguage: 'en',
        targetLanguage: 'es',
        translation: 'abre la puerta',
        tokens: [
          token('open', lemma: 'open', target: 'abrir', partOfSpeech: 'VERB'),
          token('door', lemma: 'door', target: 'puerta'),
        ],
      );
      await enrichment.enrichNow(first);

      final second = await say('she opens it');
      backend.responses['she opens it'] = RemoteTranslation(
        sourceText: 'she opens it',
        sourceLanguage: 'en',
        targetLanguage: 'es',
        translation: 'ella lo abre',
        tokens: [
          token('opens', lemma: 'open', target: 'abrir', partOfSpeech: 'VERB'),
        ],
      );
      await enrichment.enrichNow(second);

      final open = (await entries()).where((entry) => entry.lemma == 'open');
      expect(open.length, 1, reason: 'one word must not become two rows');
      expect(
        open.single.seenCount,
        2,
        reason: 'both sentences count towards the merged entry',
      );
    });
  });

  group('when the backend is unreachable', () {
    test('the sentence keeps its on-device translation and stays queued',
        () async {
      final saved = await say('the bakery is closed');
      backend.failure = const ApiException(ApiFailureKind.unreachable);

      await enrichment.enrichNow(saved);

      final reloaded = await utterances.byId(saved.id);
      expect(reloaded!.translationText, 'rough translation');
      expect(reloaded.enrichmentState, EnrichmentState.pending);
      expect(enrichment.status.value.lastError, ApiFailureKind.unreachable);
    });

    test('a sentence the server will never accept stops being retried',
        () async {
      final saved = await say('the bakery is closed');
      backend.failure = const ApiException(
        ApiFailureKind.rejected,
        code: 'UNSUPPORTED_LANGUAGE_PAIR',
      );

      await enrichment.drainQueue();

      final reloaded = await utterances.byId(saved.id);
      expect(reloaded!.enrichmentState, EnrichmentState.failed);
      expect(await utterances.pendingEnrichment(), isEmpty);
    });
  });

  group('draining the backlog', () {
    test('enriches everything that accumulated offline', () async {
      for (var i = 0; i < 3; i++) {
        await say('sentence $i');
      }

      await enrichment.drainQueue();

      expect(backend.requested.length, 3);
      expect(await utterances.pendingEnrichment(), isEmpty);
    });

    test('stops on the first retryable failure rather than hammering',
        () async {
      for (var i = 0; i < 3; i++) {
        await say('sentence $i');
      }
      backend.failure = const ApiException(ApiFailureKind.throttled);

      await enrichment.drainQueue();

      expect(backend.requested.length, 1);
      expect((await utterances.pendingEnrichment()).length, 3);
    });

    test('two triggers at once drain the queue only once', () async {
      await say('the bakery is closed');

      await Future.wait([enrichment.drainQueue(), enrichment.drainQueue()]);

      expect(backend.requested.length, 1);
    });

    test('caps how much it takes on after a long time offline', () async {
      for (var i = 0; i < EnrichmentService.batchSize + 5; i++) {
        await say('sentence $i');
      }

      await enrichment.drainQueue();

      expect(backend.requested.length, EnrichmentService.batchSize);
      expect((await utterances.pendingEnrichment()).length, 5);
    });
  });
}

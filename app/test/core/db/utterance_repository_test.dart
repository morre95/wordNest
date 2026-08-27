import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/db/tables.dart';

void main() {
  late WordNestDatabase db;
  late GlossaryRepository glossary;
  late UtteranceRepository utterances;
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
  });

  tearDown(() => db.close());

  test('a finalised utterance is stored with its pair and timestamp', () async {
    final saved = await utterances.saveFinalised(
      sourceText: 'the bakery opens early',
      translationText: 'la panadería abre temprano',
      pair: englishToSpanish,
    );

    expect(saved.sourceText, 'the bakery opens early');
    expect(saved.sourceLanguage, 'en');
    expect(saved.targetLanguage, 'es');
    expect(saved.spokenAt, now);
    expect(saved.enrichmentState, EnrichmentState.pending);
    expect(saved.dirty, isTrue, reason: 'a new row has not been synced yet');
  });

  test('ids are client-generated and sort chronologically', () async {
    final first = await utterances.saveFinalised(
      sourceText: 'one',
      translationText: 'uno',
      pair: englishToSpanish,
    );
    now = now.add(const Duration(seconds: 5));
    final second = await utterances.saveFinalised(
      sourceText: 'two',
      translationText: 'dos',
      pair: englishToSpanish,
    );

    expect(first.id, isNot(second.id));
    expect(first.id.compareTo(second.id), lessThan(0));
  });

  test('saving an utterance fills the glossary with its content words',
      () async {
    await utterances.saveFinalised(
      sourceText: 'the bakery opens early',
      translationText: 'la panadería abre temprano',
      pair: englishToSpanish,
    );

    final entries = await glossary
        .watchEntries(sort: GlossarySort.alphabetical)
        .first;

    expect(
      entries.map((row) => row.entry.lemma),
      ['bakery', 'early', 'opens'],
      reason: '"the" is a function word and should not be collected',
    );
    expect(entries.every((row) => row.entry.seenCount == 1), isTrue);
  });

  test('a repeated word increments its count instead of duplicating',
      () async {
    await utterances.saveFinalised(
      sourceText: 'the bakery is closed',
      translationText: '…',
      pair: englishToSpanish,
    );
    now = now.add(const Duration(minutes: 1));
    await utterances.saveFinalised(
      sourceText: 'which bakery',
      translationText: '…',
      pair: englishToSpanish,
    );

    final entries = await glossary.watchEntries().first;
    final bakery =
        entries.singleWhere((row) => row.entry.lemma == 'bakery').entry;

    expect(bakery.seenCount, 2);
    expect(
      entries.where((row) => row.entry.lemma == 'bakery').length,
      1,
      reason: 'the same word in the same direction is one entry',
    );
  });

  test('the same word in the other direction is a separate entry', () async {
    await utterances.saveFinalised(
      sourceText: 'bakery',
      translationText: 'panadería',
      pair: englishToSpanish,
    );
    await utterances.saveFinalised(
      sourceText: 'bakery',
      translationText: 'bageri',
      pair: const LanguagePair(
        source: Language(code: 'en', name: 'English'),
        target: Language(code: 'sv', name: 'Swedish'),
      ),
    );

    final entries = await glossary.watchEntries().first;

    expect(entries.where((row) => row.entry.lemma == 'bakery').length, 2);
  });

  test('the example sentence follows the most recent hearing', () async {
    await utterances.saveFinalised(
      sourceText: 'an old bakery',
      translationText: '…',
      pair: englishToSpanish,
    );
    now = now.add(const Duration(minutes: 1));
    final newer = await utterances.saveFinalised(
      sourceText: 'a new bakery',
      translationText: '…',
      pair: englishToSpanish,
    );

    final entries = await glossary.watchEntries().first;
    final bakery = entries.singleWhere((row) => row.entry.lemma == 'bakery');

    expect(bakery.entry.exampleUtteranceId, newer.id);
    expect(bakery.example?.sourceText, 'a new bakery');
  });

  test('enrichment replaces the on-device translation in place', () async {
    final saved = await utterances.saveFinalised(
      sourceText: 'it is raining',
      translationText: 'esta lloviendo',
      pair: englishToSpanish,
    );

    await utterances.applyEnrichment(
      saved.id,
      translationText: 'está lloviendo',
      literalGloss: 'it is raining',
    );

    final reloaded = await utterances.byId(saved.id);
    expect(reloaded!.translationText, 'está lloviendo');
    expect(reloaded.literalGloss, 'it is raining');
    expect(reloaded.enrichmentState, EnrichmentState.enriched);
    expect(reloaded.id, saved.id, reason: 'enrichment must not renumber a row');
  });

  test('rows awaiting the backend come back oldest first', () async {
    final first = await utterances.saveFinalised(
      sourceText: 'first',
      translationText: '…',
      pair: englishToSpanish,
    );
    now = now.add(const Duration(minutes: 1));
    final second = await utterances.saveFinalised(
      sourceText: 'second',
      translationText: '…',
      pair: englishToSpanish,
    );
    await utterances.applyEnrichment(first.id, translationText: 'primero');

    final pending = await utterances.pendingEnrichment();

    expect(pending.map((row) => row.id), [second.id]);
  });

  test('deleting leaves a tombstone rather than removing the row', () async {
    final saved = await utterances.saveFinalised(
      sourceText: 'forget this',
      translationText: '…',
      pair: englishToSpanish,
    );

    await utterances.delete(saved.id);

    final reloaded = await utterances.byId(saved.id);
    expect(reloaded, isNotNull, reason: 'the row must survive to be synced');
    expect(reloaded!.deletedAt, isNotNull);
    expect(reloaded.dirty, isTrue);
    expect(await utterances.watchRecent().first, isEmpty);
  });
}

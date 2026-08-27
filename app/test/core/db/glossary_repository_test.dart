import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';

void main() {
  late WordNestDatabase db;
  late GlossaryRepository glossary;
  late UtteranceRepository utterances;
  var now = DateTime.utc(2026, 3, 1, 9);

  const englishToSpanish = LanguagePair(
    source: Language(code: 'en', name: 'English'),
    target: Language(code: 'es', name: 'Spanish'),
  );
  const englishToSwedish = LanguagePair(
    source: Language(code: 'en', name: 'English'),
    target: Language(code: 'sv', name: 'Swedish'),
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

  Future<void> say(String sentence, {LanguagePair pair = englishToSpanish}) async {
    await utterances.saveFinalised(
      sourceText: sentence,
      translationText: '…',
      pair: pair,
    );
    now = now.add(const Duration(minutes: 1));
  }

  Future<List<String>> lemmas({
    String search = '',
    String? languagePairKey,
    GlossaryDifficulty difficulty = GlossaryDifficulty.all,
    GlossarySort sort = GlossarySort.recency,
  }) async {
    final rows = await glossary
        .watchEntries(
          search: search,
          languagePairKey: languagePairKey,
          difficulty: difficulty,
          sort: sort,
        )
        .first;
    return rows.map((row) => row.entry.lemma).toList(growable: false);
  }

  group('search', () {
    test('matches the source word', () async {
      await say('the bakery is closed');

      expect(await lemmas(search: 'bak'), ['bakery']);
    });

    test('matches the target-language form once enrichment fills it in',
        () async {
      await say('bakery');
      final entry = (await glossary.watchEntries().first).single.entry;
      await (db.update(db.glossaryEntries)
            ..where((row) => row.id.equals(entry.id)))
          .write(const GlossaryEntriesCompanion(
            targetForm: Value('panadería'),
          ));

      expect(await lemmas(search: 'panad'), ['bakery']);
    });

    test('is case-insensitive', () async {
      await say('Bakery');

      expect(await lemmas(search: 'BAKERY'), ['bakery']);
    });

    test('an unmatched search returns nothing rather than everything',
        () async {
      await say('the bakery is closed');

      expect(await lemmas(search: 'zzz'), isEmpty);
    });
  });

  group('filters', () {
    test('by language pair', () async {
      await say('bakery');
      await say('harbour', pair: englishToSwedish);

      expect(await lemmas(languagePairKey: 'en-es'), ['bakery']);
      expect(await lemmas(languagePairKey: 'en-sv'), ['harbour']);
    });

    test('by struggle, which includes explicitly flagged words', () async {
      await say('bakery harbour');
      final rows = await glossary.watchEntries().first;
      final bakery = rows.singleWhere((row) => row.entry.lemma == 'bakery');
      await glossary.setFlagged(bakery.entry.id, isFlagged: true);

      expect(await lemmas(difficulty: GlossaryDifficulty.struggling),
          ['bakery']);
    });

    test('by struggle, which includes words with a low ease factor', () async {
      await say('bakery harbour');
      final rows = await glossary.watchEntries().first;
      final harbour = rows.singleWhere((row) => row.entry.lemma == 'harbour');
      await (db.update(db.glossaryEntries)
            ..where((row) => row.id.equals(harbour.entry.id)))
          .write(const GlossaryEntriesCompanion(easeFactor: Value(1.6)));

      expect(await lemmas(difficulty: GlossaryDifficulty.struggling),
          ['harbour']);
    });

    test('by due, which excludes entries never reviewed', () async {
      await say('bakery harbour');
      final rows = await glossary.watchEntries().first;
      final bakery = rows.singleWhere((row) => row.entry.lemma == 'bakery');
      await (db.update(db.glossaryEntries)
            ..where((row) => row.id.equals(bakery.entry.id)))
          .write(GlossaryEntriesCompanion(
            dueAt: Value(now.subtract(const Duration(days: 1))),
          ));

      expect(await lemmas(difficulty: GlossaryDifficulty.due), ['bakery']);
    });
  });

  group('sorting', () {
    test('by recency puts the most recently heard word first', () async {
      await say('bakery');
      await say('harbour');

      expect(await lemmas(sort: GlossarySort.recency), ['harbour', 'bakery']);
    });

    test('by struggle puts flagged words above low-ease words', () async {
      await say('bakery harbour lighthouse');
      final rows = await glossary.watchEntries().first;
      final byLemma = {for (final row in rows) row.entry.lemma: row.entry.id};
      await glossary.setFlagged(byLemma['lighthouse']!, isFlagged: true);
      await (db.update(db.glossaryEntries)
            ..where((row) => row.id.equals(byLemma['harbour']!)))
          .write(const GlossaryEntriesCompanion(easeFactor: Value(1.5)));

      expect(
        await lemmas(sort: GlossarySort.struggle),
        ['lighthouse', 'harbour', 'bakery'],
      );
    });
  });

  group('entry lifecycle', () {
    test('every sentence a word appeared in is retrievable', () async {
      await say('the bakery is closed');
      await say('which bakery');

      final entry = (await glossary.watchEntries(search: 'bakery').first)
          .single
          .entry;
      final examples = await glossary.watchOccurrences(entry.id).first;

      expect(
        examples.map((row) => row.sourceText),
        ['which bakery', 'the bakery is closed'],
      );
    });

    test('deleting an entry hides it but keeps a tombstone', () async {
      await say('bakery');
      final entry = (await glossary.watchEntries().first).single.entry;

      await glossary.delete(entry.id);

      expect(await lemmas(), isEmpty);
      final tombstone = await (db.select(db.glossaryEntries)
            ..where((row) => row.id.equals(entry.id)))
          .getSingle();
      expect(tombstone.deletedAt, isNotNull);
      expect(tombstone.dirty, isTrue);
    });

    test('saying a deleted word again brings it back', () async {
      await say('bakery');
      final entry = (await glossary.watchEntries().first).single.entry;
      await glossary.delete(entry.id);

      await say('bakery');

      expect(await lemmas(), ['bakery']);
      final revived = (await glossary.watchEntries().first).single.entry;
      expect(revived.id, entry.id, reason: 'the same word is the same row');
      expect(revived.seenCount, 2);
    });

    test('the language pairs present drive the filter options', () async {
      await say('bakery');
      await say('harbour', pair: englishToSwedish);

      expect(
        (await glossary.watchLanguagePairKeys().first)..sort(),
        ['en-es', 'en-sv'],
      );
    });

    test('an empty glossary counts as zero rather than failing', () async {
      expect(await glossary.count(), 0);
      expect(await lemmas(), isEmpty);
    });
  });
}

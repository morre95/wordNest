import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/review_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/review/scheduler.dart';

void main() {
  late WordNestDatabase db;
  late GlossaryRepository glossary;
  late UtteranceRepository utterances;
  late ReviewRepository reviews;
  var now = DateTime.utc(2026, 3, 2, 9);

  const englishToSpanish = LanguagePair(
    source: Language(code: 'en', name: 'English'),
    target: Language(code: 'es', name: 'Spanish'),
  );

  setUp(() {
    now = DateTime.utc(2026, 3, 2, 9);
    db = WordNestDatabase.memory();
    glossary = GlossaryRepository(database: db, clock: () => now);
    utterances = UtteranceRepository(
      database: db,
      glossaryRepository: glossary,
      clock: () => now,
    );
    reviews = ReviewRepository(database: db, clock: () => now);
  });

  tearDown(() => db.close());

  Future<void> say(String sentence) async {
    await utterances.saveFinalised(
      sourceText: sentence,
      translationText: '…',
      pair: englishToSpanish,
    );
    now = now.add(const Duration(minutes: 1));
  }

  Future<GlossaryEntry> entryFor(String lemma) async {
    final rows = await glossary.watchEntries(search: lemma).first;
    return rows.firstWhere((row) => row.entry.lemma == lemma).entry;
  }

  Future<List<String>> queue() async {
    final cards = await reviews.dueCards();
    return cards.map((card) => card.entry.lemma).toList(growable: false);
  }

  group('the queue', () {
    test('a word never reviewed is due straight away', () async {
      await say('the bakery is closed');

      expect(await queue(), containsAll(['bakery', 'closed']));
    });

    test('an empty glossary produces an empty queue', () async {
      expect(await queue(), isEmpty);
    });

    test('a word just reviewed drops out until it is due again', () async {
      await say('bakery harbour');
      await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.good,
      );

      expect(await queue(), ['harbour']);
    });

    test('it comes back once the interval has passed', () async {
      await say('bakery');
      await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.good,
      );

      now = now.add(const Duration(days: 2));

      expect(await queue(), ['bakery']);
    });

    test('a flagged word is offered even when it is not due', () async {
      await say('bakery harbour');
      final bakery = await entryFor('bakery');
      await reviews.recordReview(bakery, grade: ReviewGrade.easy);
      await glossary.setFlagged(bakery.id, isFlagged: true);

      expect(await queue(), contains('bakery'));
    });

    test('the most urgent word comes first', () async {
      await say('bakery harbour lighthouse');
      // Everything is due; the flag is what should decide the order.
      await glossary.setFlagged(
        (await entryFor('lighthouse')).id,
        isFlagged: true,
      );

      expect((await queue()).first, 'lighthouse');
    });

    test('a deleted word is never offered', () async {
      await say('bakery harbour');
      await glossary.delete((await entryFor('bakery')).id);

      expect(await queue(), ['harbour']);
    });

    test('a session is capped so it can be finished', () async {
      // Distinct alphabetic words: the extractor drops digits, so "word1" and
      // "word2" would be one lemma.
      for (var index = 0; index < 40; index++) {
        final letters =
            String.fromCharCodes([97 + index ~/ 26, 97 + index % 26]);
        await say('${letters}ord');
      }

      expect(
        (await reviews.dueCards()).length,
        ReviewRepository.defaultSessionSize,
      );
    });
  });

  group('recording a review', () {
    test('writes the new schedule onto the entry', () async {
      await say('bakery');

      final next = await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.good,
      );

      final entry = await entryFor('bakery');
      expect(entry.intervalDays, next.intervalDays);
      expect(entry.easeFactor, closeTo(next.easeFactor, 0.0001));
      expect(entry.repetitionCount, 1);
      expect(entry.dueAt, next.dueAt);
      expect(entry.lastReviewedAt, now);
      expect(entry.dirty, isTrue, reason: 'the change has to reach sync');
    });

    test('appends an immutable log of what happened', () async {
      await say('bakery');
      final entry = await entryFor('bakery');

      await reviews.recordReview(entry, grade: ReviewGrade.hard);
      await reviews.recordReview(await entryFor('bakery'),
          grade: ReviewGrade.good);

      final logs = await db.select(db.reviewLogs).get();
      expect(logs.length, 2);
      expect(logs.map((log) => log.grade), [3, 4]);
      expect(logs.every((log) => log.glossaryEntryId == entry.id), isTrue);
    });

    test('the log records the schedule it produced', () async {
      await say('bakery');

      final next = await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.good,
      );

      final log = (await db.select(db.reviewLogs).get()).single;
      expect(log.scheduledIntervalDays, next.intervalDays);
      expect(log.scheduledEaseFactor, closeTo(next.easeFactor, 0.0001));
    });

    test('forgetting a word brings it straight back tomorrow', () async {
      await say('bakery');
      await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.good,
      );
      now = now.add(const Duration(days: 2));

      await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.forgot,
      );

      final entry = await entryFor('bakery');
      expect(entry.intervalDays, 1);
      expect(entry.repetitionCount, 0);
      expect(entry.easeFactor, lessThan(2.5));
    });
  });

  group('the due count', () {
    test('counts what is waiting', () async {
      await say('bakery harbour');

      expect(await reviews.watchDueCount().first, 2);
    });

    test('drops as words are reviewed', () async {
      await say('bakery harbour');
      await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.good,
      );

      expect(await reviews.watchDueCount().first, 1);
    });
  });

  group('statistics', () {
    test('an empty glossary reports zeroes rather than failing', () async {
      final stats = await reviews.statistics();

      expect(stats.isEmpty, isTrue);
      expect(stats.wordCount, 0);
      expect(stats.reviewCount, 0);
    });

    test('counts words, sentences and reviews', () async {
      await say('the bakery is closed');
      await say('a quiet harbour');
      await reviews.recordReview(
        await entryFor('bakery'),
        grade: ReviewGrade.good,
      );

      final stats = await reviews.statistics();

      expect(stats.wordCount, 4);
      expect(stats.utteranceCount, 2);
      expect(stats.reviewCount, 1);
      expect(stats.languagePairs, 1);
    });

    test('counts what the user finds hard', () async {
      await say('bakery harbour');
      await glossary.setFlagged((await entryFor('bakery')).id, isFlagged: true);
      await (db.update(db.glossaryEntries)
            ..where((row) => row.lemma.equals('harbour')))
          .write(const GlossaryEntriesCompanion(easeFactor: Value(1.5)));

      final stats = await reviews.statistics();

      expect(stats.strugglingCount, 2);
    });

    test('counts words that are sticking', () async {
      await say('bakery');
      for (var attempt = 0; attempt < 3; attempt++) {
        await reviews.recordReview(
          await entryFor('bakery'),
          grade: ReviewGrade.good,
        );
        now = now.add(const Duration(days: 10));
      }

      expect((await reviews.statistics()).learnedCount, 1);
    });
  });
}

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/review_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/providers.dart';
import 'package:wordnest/core/theme/wordnest_theme.dart';
import 'package:wordnest/features/review/review_screen.dart';

import '../../fakes/fake_speaker.dart';

void main() {
  late WordNestDatabase db;
  late GlossaryRepository glossary;
  late UtteranceRepository utterances;
  late ReviewRepository reviews;
  late FakeSpeaker speaker;
  var now = DateTime.utc(2026, 3, 2, 9);

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
    speaker = FakeSpeaker();
  });

  tearDown(() => db.close());

  Future<void> say(String sentence) async {
    await utterances.saveFinalised(
      sourceText: sentence,
      translationText: '…',
      pair: const LanguagePair(
        source: Language(code: 'en', name: 'English'),
        target: Language(code: 'es', name: 'Spanish'),
      ),
    );
    now = now.add(const Duration(minutes: 1));
  }

  /// The review screen shows a spinner while loading, so `pumpAndSettle` never
  /// settles. Bounded pumps instead.
  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpReview(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          reviewRepositoryProvider.overrideWithValue(reviews),
          speakerProvider.overrideWithValue(speaker),
        ],
        child: MaterialApp(
          theme: WordNestTheme.light(),
          home: const ReviewScreen(),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('an empty queue says so rather than showing a blank card',
      (tester) async {
    await pumpReview(tester);

    expect(find.byKey(const Key('review.finished')), findsOneWidget);
    expect(find.text('Nothing to review'), findsOneWidget);
  });

  testWidgets('the answer is hidden until the user has tried to recall it',
      (tester) async {
    await say('bakery');
    await pumpReview(tester);

    expect(find.byKey(const Key('review.prompt')), findsOneWidget);
    expect(find.byKey(const Key('review.answer')), findsNothing);
    expect(find.byKey(const Key('review.grade.good')), findsNothing);

    await tester.tap(find.byKey(const Key('review.reveal')));
    await settle(tester);

    expect(find.byKey(const Key('review.answer')), findsOneWidget);
    expect(find.byKey(const Key('review.grade.good')), findsOneWidget);
  });

  testWidgets('grading records the review and moves to the next word',
      (tester) async {
    await say('the bakery is closed');
    await pumpReview(tester);
    expect(find.text('1 of 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('review.reveal')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('review.grade.good')));
    await settle(tester);

    expect(find.text('2 of 2'), findsOneWidget);
    final logs = await tester.runAsync(
      () async => db.select(db.reviewLogs).get(),
    );
    expect(logs, hasLength(1));
  });

  testWidgets('finishing the queue reports what was done', (tester) async {
    await say('bakery');
    await pumpReview(tester);

    await tester.tap(find.byKey(const Key('review.reveal')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('review.grade.easy')));
    await settle(tester);

    expect(find.text('Done for now'), findsOneWidget);
    expect(find.textContaining('reviewed 1 word'), findsOneWidget);
  });

  testWidgets('skipping records nothing, so the word stays due',
      (tester) async {
    await say('the bakery is closed');
    await pumpReview(tester);

    await tester.tap(find.byKey(const Key('review.skip')));
    await settle(tester);

    final logs = await tester.runAsync(
      () async => db.select(db.reviewLogs).get(),
    );
    expect(logs, isEmpty);
    expect(find.text('2 of 2'), findsOneWidget);
  });

  testWidgets('a word can be marked hard from the card', (tester) async {
    await say('bakery');
    await pumpReview(tester);

    await tester.tap(find.byKey(const Key('review.flag')));
    await settle(tester);

    expect(find.text('Marked hard'), findsOneWidget);
    final entries = await tester.runAsync(
      () async => glossary.watchEntries().first,
    );
    expect(entries!.single.entry.isFlagged, isTrue);
  });

  testWidgets('the answer can be heard in the target language', (tester) async {
    await say('bakery');
    await tester.runAsync(() async {
      final entry = (await glossary.watchEntries().first).single.entry;
      await (db.update(db.glossaryEntries)
            ..where((row) => row.id.equals(entry.id)))
          .write(const GlossaryEntriesCompanion(
            targetForm: Value('panadería'),
          ));
    });
    await pumpReview(tester);

    await tester.tap(find.byKey(const Key('review.reveal')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('review.listen')));
    await settle(tester);

    expect(speaker.spoken.single.text, 'panadería');
    expect(speaker.spoken.single.languageCode, 'es');
  });

  testWidgets('a language with no voice explains itself instead of failing',
      (tester) async {
    speaker.voices.remove('es');
    await say('bakery');
    await tester.runAsync(() async {
      final entry = (await glossary.watchEntries().first).single.entry;
      await (db.update(db.glossaryEntries)
            ..where((row) => row.id.equals(entry.id)))
          .write(const GlossaryEntriesCompanion(
            targetForm: Value('panadería'),
          ));
    });
    await pumpReview(tester);

    await tester.tap(find.byKey(const Key('review.reveal')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('review.listen')));
    await settle(tester);

    expect(
      find.text('This device has no voice for that language yet.'),
      findsOneWidget,
    );
  });
}

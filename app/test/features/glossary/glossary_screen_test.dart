import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/providers.dart';
import 'package:wordnest/core/theme/wordnest_theme.dart';
import 'package:wordnest/features/glossary/glossary_entry_screen.dart';
import 'package:wordnest/features/glossary/glossary_screen.dart';
import 'package:wordnest/features/glossary/widgets/glossary_row.dart';

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

  Future<void> say(String sentence) async {
    await utterances.saveFinalised(
      sourceText: sentence,
      translationText: '…',
      pair: englishToSpanish,
    );
    now = now.add(const Duration(minutes: 1));
  }

  /// Reads a drift stream from inside a widget test. `testWidgets` runs in a
  /// fake-async zone whose clock only advances on `pump`, and a drift `watch()`
  /// never delivers its first event there. Awaiting one directly deadlocks the
  /// test, so stream reads have to happen on the real event loop.
  Future<T> onRealClock<T>(WidgetTester tester, Future<T> Function() read) async {
    late T result;
    await tester.runAsync(() async {
      result = await read();
      // Let any stream the widget tree is listening to deliver on this same
      // real clock, so the following `pump` sees the change.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    return result;
  }

  /// Drift streams deliver asynchronously, so a few bounded pumps are needed.
  /// `pumpAndSettle` is not usable here: the loading state shows a
  /// CircularProgressIndicator, whose animation never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpGlossary(WidgetTester tester, {Widget? home}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: WordNestTheme.light(),
          home: home ?? const GlossaryScreen(),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('an empty glossary explains itself instead of showing a blank',
      (tester) async {
    await pumpGlossary(tester);

    expect(find.text('Your nest is empty'), findsOneWidget);
    expect(find.byKey(const Key('glossary.list')), findsNothing);
  });

  testWidgets('lists the words from what was said, newest first',
      (tester) async {
    await say('the bakery is closed');
    await say('a quiet harbour');
    await pumpGlossary(tester);

    expect(find.byType(GlossaryRow), findsNWidgets(4));
    final rows = tester.widgetList<GlossaryRow>(find.byType(GlossaryRow));
    expect(rows.first.row.entry.lemma, anyOf('quiet', 'harbour'));
  });

  testWidgets('search narrows the list to matching words', (tester) async {
    await say('the bakery is closed');
    await say('a quiet harbour');
    await pumpGlossary(tester);

    await tester.enterText(find.byKey(const Key('glossary.search')), 'bak');
    await settle(tester);

    expect(find.byType(GlossaryRow), findsOneWidget);
    expect(find.text('bakery'), findsOneWidget);
  });

  testWidgets('a search that matches nothing offers to clear the filters',
      (tester) async {
    await say('the bakery is closed');
    await pumpGlossary(tester);

    await tester.enterText(find.byKey(const Key('glossary.search')), 'zzz');
    await settle(tester);

    expect(find.text('Nothing matches'), findsOneWidget);
    expect(find.text('Clear filters'), findsOneWidget);
  });

  testWidgets('starring a word from the list marks it difficult',
      (tester) async {
    await say('bakery');
    await pumpGlossary(tester);

    await tester.tap(find.byTooltip('Mark as difficult'));
    await settle(tester);

    final entry = await onRealClock(
      tester,
      () async => (await glossary.watchEntries().first).single.entry,
    );
    expect(entry.isFlagged, isTrue);
    expect(find.byTooltip('Unmark as difficult'), findsOneWidget);
  });

  testWidgets('the struggling filter hides words the user has not flagged',
      (tester) async {
    await say('bakery harbour');
    await onRealClock(tester, () async {
      final rows = await glossary.watchEntries().first;
      await glossary.setFlagged(
        rows.singleWhere((row) => row.entry.lemma == 'bakery').entry.id,
        isFlagged: true,
      );
    });
    await pumpGlossary(tester);

    await tester.tap(find.byKey(const Key('glossary.filter.struggling')));
    await settle(tester);

    expect(find.byType(GlossaryRow), findsOneWidget);
    expect(find.text('bakery'), findsOneWidget);
  });

  testWidgets('the detail view shows every sentence the word appeared in',
      (tester) async {
    await say('the bakery is closed');
    await say('which bakery');
    final entry = await onRealClock(
      tester,
      () async =>
          (await glossary.watchEntries(search: 'bakery').first).single.entry,
    );

    await pumpGlossary(tester, home: GlossaryEntryScreen(entryId: entry.id));

    expect(find.text('the bakery is closed'), findsOneWidget);
    expect(find.text('which bakery'), findsOneWidget);
    expect(find.text('said 2 times'), findsOneWidget);
    expect(find.text('Not translated yet'), findsOneWidget);
  });

  testWidgets('a word removed while its detail view is open says so',
      (tester) async {
    await say('bakery');
    final entry = await onRealClock(
      tester,
      () async => (await glossary.watchEntries().first).single.entry,
    );
    await pumpGlossary(tester, home: GlossaryEntryScreen(entryId: entry.id));

    await onRealClock(tester, () => glossary.delete(entry.id));
    await settle(tester);

    expect(find.text('No longer in your glossary'), findsOneWidget);
  });
}

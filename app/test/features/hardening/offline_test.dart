import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/auth/session_manager.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/review_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/network/api_exception.dart';
import 'package:wordnest/core/providers.dart';
import 'package:wordnest/core/theme/wordnest_theme.dart';
import 'package:wordnest/features/glossary/glossary_screen.dart';
import 'package:wordnest/features/glossary/widgets/glossary_row.dart';
import 'package:wordnest/features/review/review_screen.dart';
import 'package:wordnest/features/settings/settings_screen.dart';
import 'package:wordnest/features/speak/speak_screen.dart';
import 'package:wordnest/features/speak/widgets/mic_button.dart';

import '../../fakes/fake_backend_translator.dart';
import '../../fakes/fake_session.dart';
import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

/// With the backend unreachable, every screen has to keep working. The app is
/// local-first: the network is an enhancement, and its absence is a fact to
/// state plainly, never an error to show.
void main() {
  late WordNestDatabase db;
  late GlossaryRepository glossary;
  late UtteranceRepository utterances;
  late FakeAuthApi auth;

  const englishToSpanish = LanguagePair(
    source: Language(code: 'en', name: 'English'),
    target: Language(code: 'es', name: 'Spanish'),
  );

  setUp(() {
    db = WordNestDatabase.memory();
    glossary = GlossaryRepository(database: db);
    utterances = UtteranceRepository(
      database: db,
      glossaryRepository: glossary,
    );
    auth = FakeAuthApi()
      ..failure = const ApiException(ApiFailureKind.unreachable);
  });

  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Everything overridden to fail the way it fails with no network.
  List<Override> offlineOverrides() {
    final manager = SessionManager(
      authApi: auth,
      sessionStore: InMemorySessionStore(),
      deviceIdentity: FakeDeviceIdentity(),
    );
    addTearDown(manager.dispose);
    return [
      ...speakOverrides(
        recognizer: FakeSpeechRecognizer(),
        translator: FakeTranslator(),
        database: db,
        backendTranslator: FakeBackendTranslator()
          ..failure = const ApiException(ApiFailureKind.unreachable),
      ),
      sessionManagerProvider.overrideWithValue(manager),
      reviewRepositoryProvider
          .overrideWithValue(ReviewRepository(database: db)),
    ];
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: offlineOverrides(),
        child: MaterialApp(theme: WordNestTheme.light(), home: home),
      ),
    );
    await settle(tester);
  }

  Future<void> say(String sentence) async {
    await utterances.saveFinalised(
      sourceText: sentence,
      translationText: '[es] $sentence',
      pair: englishToSpanish,
    );
  }

  group('the speak screen', () {
    testWidgets('still listens with the backend down', (tester) async {
      await pump(tester, const SpeakScreen());

      await tester.tap(find.byType(MicButton));
      await tester.pump();

      expect(find.byKey(const Key('speak.notice')), findsNothing);
    });

    testWidgets('a backend that is down is never mentioned to the user',
        (tester) async {
      // The on-device translation is on screen and the sentence is saved.
      // There is nothing the user could do about the backend, so there is
      // nothing to tell them.
      await pump(tester, const SpeakScreen());
      final recognizer = ProviderScope.containerOf(
        tester.element(find.byType(SpeakScreen)),
      ).read(speechRecognizerProvider) as FakeSpeechRecognizer;

      await tester.tap(find.byType(MicButton));
      await tester.pump();
      recognizer.emitFinal('the bakery is closed');
      await settle(tester);

      expect(find.text('[es] the bakery is closed'), findsOneWidget);
      expect(find.byKey(const Key('speak.notice')), findsNothing);
      final saved = await tester.runAsync(
        () async => db.select(db.utterances).get(),
      );
      expect(saved, hasLength(1));
    });
  });

  group('the glossary', () {
    testWidgets('reads from the device and needs no network', (tester) async {
      await say('the bakery is closed');

      await pump(tester, const GlossaryScreen());

      expect(find.byType(GlossaryRow), findsNWidgets(2));
    });

    testWidgets('search works offline', (tester) async {
      await say('the bakery is closed');
      await pump(tester, const GlossaryScreen());

      await tester.enterText(find.byKey(const Key('glossary.search')), 'bak');
      await settle(tester);

      expect(find.text('bakery'), findsOneWidget);
    });
  });

  group('review', () {
    testWidgets('runs entirely offline', (tester) async {
      await say('the bakery is closed');

      await pump(tester, const ReviewScreen());

      expect(find.byKey(const Key('review.prompt')), findsOneWidget);
      await tester.tap(find.byKey(const Key('review.reveal')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('review.grade.good')));
      await settle(tester);

      final logs = await tester.runAsync(
        () async => db.select(db.reviewLogs).get(),
      );
      expect(logs, hasLength(1));
    });
  });

  group('settings', () {
    testWidgets('says what is true rather than showing an error',
        (tester) async {
      await pump(tester, const SettingsScreen());

      expect(find.text('Not connected yet'), findsOneWidget);
      expect(
        find.textContaining('saved on this device'),
        findsWidgets,
      );
    });

    testWidgets('a device list that cannot be fetched is explained',
        (tester) async {
      await pump(tester, const SettingsScreen());

      expect(find.text('Your devices could not be listed'), findsOneWidget);
      expect(find.textContaining('Nothing is lost'), findsOneWidget);
    });

    testWidgets('the privacy explanation is reachable offline', (tester) async {
      await pump(tester, const SettingsScreen());

      // Scrolled to rather than expected on the first screen: the settings
      // list is longer than a phone and "reachable" is the claim being made,
      // not "visible without moving". `scrollUntilVisible` fails the test if
      // the tile is not there at all, which is the thing worth guarding.
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings.privacy')),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.byKey(const Key('settings.privacy')), findsOneWidget);
    });
  });
}

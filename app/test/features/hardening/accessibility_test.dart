import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/theme/wordnest_theme.dart';
import 'package:wordnest/features/glossary/glossary_screen.dart';
import 'package:wordnest/features/privacy/privacy_screen.dart';
import 'package:wordnest/features/speak/speak_screen.dart';

import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

/// Every screen, against Flutter's own accessibility guidelines: tap targets
/// large enough to hit, contrast high enough to read, and a label on everything
/// a screen reader will land on.
///
/// These matter most on the speak screen, which is the one a user operates
/// without looking at it.
void main() {
  late WordNestDatabase db;

  setUp(() => db = WordNestDatabase.memory());
  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 4; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...speakOverrides(
            recognizer: FakeSpeechRecognizer(),
            translator: FakeTranslator(),
            database: db,
          ),
        ],
        child: MaterialApp(theme: WordNestTheme.light(), home: home),
      ),
    );
    await settle(tester);
  }

  /// Runs the four guideline checks Flutter ships. Each disposes its own
  /// handle, so a failure names which guideline was missed.
  Future<void> expectMeetsGuidelines(WidgetTester tester) async {
    final handle = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  }

  testWidgets('the speak screen meets the accessibility guidelines',
      (tester) async {
    await pump(tester, const SpeakScreen());

    await expectMeetsGuidelines(tester);
  });

  testWidgets('the speak screen still meets them with a transcript on it',
      (tester) async {
    final recognizer = FakeSpeechRecognizer();
    await tester.pumpWidget(
      ProviderScope(
        overrides: speakOverrides(
          recognizer: recognizer,
          translator: FakeTranslator(),
          database: db,
        ),
        child: MaterialApp(
          theme: WordNestTheme.light(),
          home: const SpeakScreen(),
        ),
      ),
    );
    await settle(tester);
    recognizer.emitFinal('the bakery is closed');
    await settle(tester);

    await expectMeetsGuidelines(tester);
  });

  testWidgets('an empty glossary meets the accessibility guidelines',
      (tester) async {
    await pump(tester, const GlossaryScreen());

    await expectMeetsGuidelines(tester);
  });

  testWidgets('a glossary with words in it meets them too', (tester) async {
    final glossary = GlossaryRepository(database: db);
    final utterances = UtteranceRepository(
      database: db,
      glossaryRepository: glossary,
    );
    await utterances.saveFinalised(
      sourceText: 'the bakery is closed',
      translationText: 'la panadería está cerrada',
      pair: const LanguagePair(
        source: Language(code: 'en', name: 'English'),
        target: Language(code: 'es', name: 'Spanish'),
      ),
    );

    await pump(tester, const GlossaryScreen());

    await expectMeetsGuidelines(tester);
  });

  testWidgets('the privacy screen meets the accessibility guidelines',
      (tester) async {
    await pump(tester, const PrivacyScreen());

    await expectMeetsGuidelines(tester);
  });

  testWidgets('the microphone is described by what it does, not what it is',
      (tester) async {
    // The one control a user operates without looking at the screen.
    await pump(tester, const SpeakScreen());
    final handle = tester.ensureSemantics();

    expect(find.bySemanticsLabel('Hold to speak'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('the privacy line is reachable by a screen reader',
      (tester) async {
    await pump(tester, const SpeakScreen());
    final handle = tester.ensureSemantics();

    expect(
      find.bySemanticsLabel(RegExp('Your voice stays on this device')),
      findsOneWidget,
    );

    handle.dispose();
  });
}

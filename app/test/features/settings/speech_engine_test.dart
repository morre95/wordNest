import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/speech_engine.dart';
import 'package:wordnest/features/settings/settings_screen.dart';

import '../../fakes/fake_speech_engine_preferences.dart';
import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

/// Choosing a recogniser, and being asked before your voice leaves the device.
void main() {
  late FakeSpeechEnginePreferences preferences;

  Future<void> pumpSettings(
    WidgetTester tester, {
    SpeechEngine engine = SpeechEngine.phone,
    bool hasAgreed = false,
  }) async {
    preferences = FakeSpeechEnginePreferences(
      stored: engine,
      hasAgreed: hasAgreed,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: speakOverrides(
          recognizer: FakeSpeechRecognizer(),
          translator: FakeTranslator(),
          engine: engine,
          enginePreferences: preferences,
        ),
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
  }

  /// The tile sits below the fold on a phone-sized test surface.
  Future<void> tapEngineTile(WidgetTester tester) async {
    final tile = find.byKey(const Key('settings.speechEngine'));
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('a device that has never chosen shows the phone', (tester) async {
    await pumpSettings(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings.speechEngine')),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.textContaining('Your phone'), findsOneWidget);
  });

  testWidgets('the picker marks the engine already in use', (tester) async {
    await pumpSettings(tester, engine: SpeechEngine.deepgram);
    await tapEngineTile(tester);

    final selected = tester.widget<ListTile>(
      find.byKey(const Key('speechEngine.deepgram')),
    );
    expect(selected.selected, isTrue);
    expect(selected.trailing, isA<Icon>());
  });

  testWidgets('choosing Deepgram asks before the voice leaves the device',
      (tester) async {
    await pumpSettings(tester);
    await tapEngineTile(tester);

    await tester.tap(find.byKey(const Key('speechEngine.deepgram')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings.deepgramConsent')), findsOneWidget);
    expect(
      find.textContaining('Your voice will leave this device'),
      findsOneWidget,
    );
  });

  testWidgets('declining leaves the setting exactly as it was', (tester) async {
    await pumpSettings(tester);
    await tapEngineTile(tester);
    await tester.tap(find.byKey(const Key('speechEngine.deepgram')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(preferences.saved, isEmpty);
    expect(preferences.stored, SpeechEngine.phone);
    expect(preferences.hasAgreed, isFalse);
  });

  testWidgets('agreeing saves the engine and the agreement', (tester) async {
    await pumpSettings(tester);
    await tapEngineTile(tester);
    await tester.tap(find.byKey(const Key('speechEngine.deepgram')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use Deepgram'));
    await tester.pumpAndSettle();

    expect(preferences.saved, [SpeechEngine.deepgram]);
    expect(preferences.hasAgreed, isTrue);
  });

  testWidgets('nobody is asked twice', (tester) async {
    // Agreed once already, then switched back to the phone. Switching to
    // Deepgram again is not a new decision about their voice.
    await pumpSettings(tester, hasAgreed: true);
    await tapEngineTile(tester);

    await tester.tap(find.byKey(const Key('speechEngine.deepgram')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings.deepgramConsent')), findsNothing);
    expect(preferences.saved, [SpeechEngine.deepgram]);
  });

  testWidgets('switching back to the phone asks nothing', (tester) async {
    await pumpSettings(tester, engine: SpeechEngine.deepgram, hasAgreed: true);
    await tapEngineTile(tester);

    await tester.tap(find.byKey(const Key('speechEngine.phone')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings.deepgramConsent')), findsNothing);
    expect(preferences.saved, [SpeechEngine.phone]);
  });

  testWidgets('the privacy tile stops claiming the voice stays on the device',
      (tester) async {
    await pumpSettings(tester, engine: SpeechEngine.deepgram, hasAgreed: true);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings.privacy')),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Your voice is never recorded'), findsNothing);
    expect(find.textContaining('on to Deepgram'), findsOneWidget);
  });
}

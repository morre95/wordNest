import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/permissions/microphone_permission.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';
import 'package:wordnest/core/theme/wordnest_theme.dart';
import 'package:wordnest/features/speak/speak_controller.dart';
import 'package:wordnest/features/speak/speak_screen.dart';
import 'package:wordnest/features/speak/widgets/mic_button.dart';

import '../../fakes/fake_microphone_permissions.dart';
import '../../fakes/fake_speaker.dart';
import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

void main() {
  late FakeSpeechRecognizer recognizer;
  late FakeTranslator translator;
  late FakeMicrophonePermissions permissions;
  late FakeSpeaker speaker;

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    translator = FakeTranslator();
    permissions = FakeMicrophonePermissions();
    speaker = FakeSpeaker();
  });

  Future<void> pumpSpeakScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: speakOverrides(
          recognizer: recognizer,
          translator: translator,
          permissions: permissions,
          speaker: speaker,
        ),
        child: MaterialApp(
          theme: WordNestTheme.light(),
          home: const SpeakScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('opens straight onto the microphone with no modal in the way',
      (tester) async {
    await pumpSpeakScreen(tester);

    expect(find.byType(MicButton), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Spanish'), findsOneWidget);
    expect(find.byKey(const Key('speak.emptyPrompt')), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('states the privacy guarantee in plain language', (tester) async {
    await pumpSpeakScreen(tester);

    expect(
      find.text('Your voice stays on this device. Nothing is recorded.'),
      findsOneWidget,
    );
  });

  testWidgets('says so when the phone recognises online instead of on-device',
      (tester) async {
    await pumpSpeakScreen(tester);

    recognizer.emitRoute(SpeechRoute.phoneOnline);
    await tester.pumpAndSettle();

    expect(
      find.text('Recognised by your phone online. Nothing is recorded.'),
      findsOneWidget,
    );
  });

  testWidgets('names both hops when the voice goes through WordNest',
      (tester) async {
    await pumpSpeakScreen(tester);

    recognizer.emitRoute(SpeechRoute.wordnestServer);
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Your voice goes to WordNest's server, then to Deepgram. "
        'Nothing is kept.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('holding the microphone starts a session and releasing ends it',
      (tester) async {
    await pumpSpeakScreen(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(MicButton)),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(recognizer.startedLanguages, ['en']);
    expect(recognizer.stopCount, 1);
  });

  testWidgets('shows the partial transcript and then the final translation',
      (tester) async {
    await pumpSpeakScreen(tester);
    await tester.tap(find.byType(MicButton));
    await tester.pump();

    recognizer.emitPartial('good evening');
    await tester.pump();
    expect(find.text('good evening'), findsOneWidget);

    // The provisional translation only appears once the debounce elapses.
    expect(find.textContaining('[es]'), findsNothing);
    await tester.pump(SpeakController.provisionalTranslationDebounce);
    await tester.pump();
    expect(find.text('[es] good evening'), findsOneWidget);

    recognizer.emitFinal('good evening, everyone');
    await tester.pump();
    await tester.pump();
    expect(find.text('good evening, everyone'), findsOneWidget);
    expect(find.text('[es] good evening, everyone'), findsOneWidget);
  });

  testWidgets('swapping languages reverses the pair shown', (tester) async {
    await pumpSpeakScreen(tester);

    await tester.tap(find.byTooltip('Swap languages'));
    await tester.pumpAndSettle();

    expect(find.text('Spanish'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SpeakScreen)),
    );
    expect(container.read(speakControllerProvider).pair.source.code, 'es');
  });

  testWidgets('a permanently denied microphone offers the settings shortcut',
      (tester) async {
    permissions.current = MicrophoneAccess.permanentlyDenied;
    await pumpSpeakScreen(tester);

    await tester.tap(find.byType(MicButton));
    await tester.pump();

    expect(find.byKey(const Key('speak.notice')), findsOneWidget);
    expect(
      find.text('Microphone access is turned off for WordNest.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Settings'));
    await tester.pump();
    expect(permissions.openSettingsCount, 1);
  });

  testWidgets('a missing offline model offers a download from the banner',
      (tester) async {
    translator.presentModels.remove('es');
    await pumpSpeakScreen(tester);
    await tester.tap(find.byType(MicButton));
    await tester.pump();

    recognizer.emitFinal('hola');
    await tester.pump();
    await tester.pump();

    expect(
      find.text('The Spanish offline model is not on this device yet.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(translator.downloaded, ['es']);
    expect(find.byKey(const Key('speak.notice')), findsNothing);
    expect(find.text('[es] hola'), findsOneWidget);
  });

  testWidgets('tapping a settled translation speaks it in the target language',
      (tester) async {
    await pumpSpeakScreen(tester);
    await tester.tap(find.byType(MicButton));
    await tester.pump();
    recognizer.emitFinal('good evening');
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('speak.translationText')));
    await tester.pump();

    expect(speaker.spoken.single.text, '[es] good evening');
    expect(speaker.spoken.single.languageCode, 'es');
  });

  testWidgets('a provisional translation is not spoken', (tester) async {
    // It is about to be replaced; hearing it would teach the wrong
    // pronunciation.
    await pumpSpeakScreen(tester);
    await tester.tap(find.byType(MicButton));
    await tester.pump();
    recognizer.emitPartial('good eve');
    await tester.pump(SpeakController.provisionalTranslationDebounce);
    await tester.pump();

    await tester.tap(find.byKey(const Key('speak.translationText')));
    await tester.pump();

    expect(speaker.spoken, isEmpty);
  });

  testWidgets('a whole sentence can be marked hard once it is saved',
      (tester) async {
    // The other explicit difficulty signal: sometimes the construction was
    // hard rather than any one word in it.
    await pumpSpeakScreen(tester);
    await tester.tap(find.byType(MicButton));
    await tester.pump();
    expect(find.byKey(const Key('speak.flagUtterance')), findsNothing);

    recognizer.emitFinal('the bakery is closed');
    for (var index = 0; index < 6; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    await tester.tap(find.byKey(const Key('speak.flagUtterance')));
    await tester.pump();

    expect(find.text('Marked as hard'), findsOneWidget);
  });

  testWidgets('hands-free turns the microphone into a toggle', (tester) async {
    await pumpSpeakScreen(tester);

    await tester.tap(find.byKey(const Key('speak.handsFreeToggle')));
    await tester.pump();
    await tester.tap(find.byType(MicButton));
    await tester.pump();

    expect(recognizer.startedModes, [ListeningMode.continuous]);
  });
}

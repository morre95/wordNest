import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/providers.dart';
import 'package:wordnest/core/speech/speech_engine.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';
import 'package:wordnest/features/speak/speak_controller.dart';

import 'package:wordnest/features/speak/speak_screen.dart';
import 'package:wordnest/features/speak/widgets/mic_button.dart';

import '../../fakes/fake_microphone_stream.dart';
import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_speech_socket.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

/// Changing the engine has to swap the running recogniser, and swap it
/// cleanly: no leaked subscription, no two recognisers alive at once, and none
/// of the user's own choices lost along the way.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<SpeechEngine, FakeSpeechRecognizer> built;

  ProviderContainer boot() {
    built = {};
    final container = ProviderContainer(
      overrides: [
        ...speakOverrides(translator: FakeTranslator()),
        // Overrides the factory rather than the recogniser, so the real
        // provider does the swapping and the test watches it happen.
        speechRecognizerFactoryProvider.overrideWithValue((engine) {
          return built[engine] = FakeSpeechRecognizer();
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('builds the recogniser the setting names', () {
    final container = boot();

    container.read(speakControllerProvider);

    expect(built.keys, [SpeechEngine.phone]);
  });

  test('changing the engine builds the other one and disposes the first',
      () async {
    final container = boot();
    container.read(speakControllerProvider);
    final first = built[SpeechEngine.phone]!;

    await container
        .read(speechEngineProvider.notifier)
        .choose(SpeechEngine.deepgram);
    container.read(speakControllerProvider);

    expect(built.keys, containsAll(SpeechEngine.values));
    expect(first.disposed, isTrue);
    expect(built[SpeechEngine.deepgram]!.disposed, isFalse);
  });

  test('the new recogniser is the one being listened to', () async {
    final container = boot();
    container.read(speakControllerProvider);

    await container
        .read(speechEngineProvider.notifier)
        .choose(SpeechEngine.deepgram);
    container.read(speakControllerProvider);

    built[SpeechEngine.deepgram]!.emitPartial('heard by the new one');
    await pumpEventQueue();

    expect(
      container.read(speakControllerProvider).sourceText,
      'heard by the new one',
    );
  });

  test('the old recogniser can no longer be heard', () async {
    final container = boot();
    container.read(speakControllerProvider);
    final old = built[SpeechEngine.phone]!;

    await container
        .read(speechEngineProvider.notifier)
        .choose(SpeechEngine.deepgram);
    container.read(speakControllerProvider);

    // A leaked subscription would let a torn-down session write to the screen.
    expect(() => old.emitPartial('a ghost'), throwsStateError);
    expect(container.read(speakControllerProvider).sourceText, '');
  });

  test("the user's language pair survives the swap", () async {
    final container = boot();
    final controller = container.read(speakControllerProvider.notifier);
    await controller.setLanguagePair(
      const LanguagePair(
        source: Language(code: 'sv', name: 'Swedish'),
        target: Language(code: 'de', name: 'German'),
      ),
    );

    await container
        .read(speechEngineProvider.notifier)
        .choose(SpeechEngine.deepgram);

    final state = container.read(speakControllerProvider);
    expect(state.pair.source.code, 'sv');
    expect(state.pair.target.code, 'de');
  });

  test('hands-free survives the swap', () async {
    final container = boot();
    final controller = container.read(speakControllerProvider.notifier);
    await controller.setMode(ListeningMode.continuous);

    await container
        .read(speechEngineProvider.notifier)
        .choose(SpeechEngine.deepgram);

    expect(
      container.read(speakControllerProvider).mode,
      ListeningMode.continuous,
    );
  });

  test('the transcript and the route do not survive the swap', () async {
    // They belonged to a session that went with the old recogniser. Showing
    // them beside a route that is no longer true would be worse than clearing.
    final container = boot();
    container.read(speakControllerProvider);
    built[SpeechEngine.phone]!
      ..emitRoute(SpeechRoute.phoneOnline)
      ..emitPartial('said to the old one');
    await pumpEventQueue();

    await container
        .read(speechEngineProvider.notifier)
        .choose(SpeechEngine.deepgram);

    final state = container.read(speakControllerProvider);
    expect(state.sourceText, '');
    expect(state.recognitionRoute, SpeechRoute.onDevice);
  });

  test('a device that stored Deepgram starts on Deepgram', () {
    final container = ProviderContainer(
      overrides: [
        ...speakOverrides(
          translator: FakeTranslator(),
          engine: SpeechEngine.deepgram,
        ),
        speechRecognizerFactoryProvider.overrideWithValue((engine) {
          return (built = {})[engine] = FakeSpeechRecognizer();
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(speakControllerProvider);

    expect(built.keys, [SpeechEngine.deepgram]);
  });

  testWidgets('backgrounding the app ends the session', (tester) async {
    // The cloud recogniser holds the microphone itself rather than borrowing
    // the platform's bounded session, so without this the app would keep
    // listening and streaming with its window out of sight — and none of the
    // privacy line would still be true.
    final microphone = FakeMicrophoneStream();
    final sockets = FakeSpeechSocketFactory();

    await tester.pumpWidget(
      ProviderScope(
        overrides: speakOverrides(
          translator: FakeTranslator(),
          engine: SpeechEngine.deepgram,
          microphone: microphone,
          sockets: sockets,
        ),
        child: const MaterialApp(home: SpeakScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(MicButton));
    await tester.pump();
    microphone.emitSpeech();
    await tester.pump();
    expect(microphone.isOpen, isTrue);

    // The real transition the OS makes, in full: Flutter asserts on skipped
    // steps, and a test that skipped one would not be exercising what happens.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Tearing a session down cancels a stream subscription, which only
    // completes on the real event loop; `runAsync` is what lets it.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(microphone.isOpen, isFalse);
    expect(sockets.socket.closed, isTrue);
  });
}

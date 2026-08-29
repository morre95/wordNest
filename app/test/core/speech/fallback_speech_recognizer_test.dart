import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/fallback_speech_recognizer.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';

import '../../fakes/fake_speech_recognizer.dart';

/// A cloud recogniser that cannot reach its server must not leave the
/// microphone dead — that is the one place the app's local-first promise would
/// stop being true.
void main() {
  late FakeSpeechRecognizer preferred;
  late FakeSpeechRecognizer fallback;
  late FallbackSpeechRecognizer recognizer;
  late List<SpeechEvent> events;

  setUp(() {
    preferred = FakeSpeechRecognizer();
    fallback = FakeSpeechRecognizer();
    recognizer = FallbackSpeechRecognizer(
      preferred: preferred,
      fallback: fallback,
    );
    events = [];
    recognizer.events.listen(events.add);
  });

  test('uses the preferred recogniser when it works', () async {
    await recognizer.start(languageCode: 'en');

    expect(preferred.startedLanguages, ['en']);
    expect(fallback.startedLanguages, isEmpty);
  });

  test('falls back to the phone when the service cannot be reached', () async {
    preferred.failOnStart = const SpeechFailure(
      SpeechFailureKind.serviceUnreachable,
      isPermanent: false,
    );

    await recognizer.start(languageCode: 'en', mode: ListeningMode.continuous);

    expect(fallback.startedLanguages, ['en']);
    expect(fallback.startedModes, [ListeningMode.continuous]);
  });

  test('the fallback says where the voice actually went', () async {
    // This is what keeps the fallback honest: the privacy line follows the
    // recogniser that ran, not the one the user picked.
    preferred.failOnStart = const SpeechFailure(
      SpeechFailureKind.serviceUnreachable,
    );
    await recognizer.start(languageCode: 'en');

    fallback.emitRoute(SpeechRoute.onDevice);
    await pumpEventQueue();

    expect(
      events.whereType<SpeechRouteChanged>().single.route,
      SpeechRoute.onDevice,
    );
  });

  test('a refused microphone is not something the phone can fix', () async {
    // Falling back here would just delay the same refusal.
    preferred.failOnStart = const SpeechFailure(
      SpeechFailureKind.permissionDenied,
    );

    await expectLater(
      recognizer.start(languageCode: 'en'),
      throwsA(isA<SpeechFailure>()),
    );
    expect(fallback.startedLanguages, isEmpty);
  });

  test('an unrecognised language is not something the phone can fix', () async {
    preferred.failOnStart = const SpeechFailure(
      SpeechFailureKind.localeUnsupported,
    );

    await expectLater(
      recognizer.start(languageCode: 'cy'),
      throwsA(isA<SpeechFailure>()),
    );
    expect(fallback.startedLanguages, isEmpty);
  });

  test('only the recogniser that is running may speak', () async {
    await recognizer.start(languageCode: 'en');

    // The idle one emitting must not be able to talk over the live session.
    fallback.emitFinal('from the wrong recogniser');
    preferred.emitFinal('from the right one');
    await pumpEventQueue();

    expect(events.whereType<SpeechFinal>().map((event) => event.text), [
      'from the right one',
    ]);
  });

  test('stop and cancel reach the recogniser that is listening', () async {
    preferred.failOnStart = const SpeechFailure(
      SpeechFailureKind.serviceUnreachable,
    );
    await recognizer.start(languageCode: 'en');

    await recognizer.stop();
    await recognizer.cancel();

    expect(fallback.stopCount, 1);
    expect(fallback.cancelCount, 1);
    expect(preferred.stopCount, 0);
  });

  test('a cancelled start cannot open an ownerless microphone', () async {
    final gate = Completer<void>();
    preferred.startGate = gate.future;

    final starting = recognizer.start(languageCode: 'en');
    await pumpEventQueue();
    await recognizer.cancel();
    gate.complete();
    await starting;

    expect(preferred.isListening, isFalse);
    expect(preferred.cancelCount, 2);
    expect(fallback.startedLanguages, isEmpty);
  });

  test('disposing takes both children with it', () async {
    await recognizer.dispose();

    // A leaked cloud recogniser would keep a microphone and a socket.
    expect(() => preferred.emitPartial('anything'), throwsStateError);
    expect(() => fallback.emitPartial('anything'), throwsStateError);
  });
}

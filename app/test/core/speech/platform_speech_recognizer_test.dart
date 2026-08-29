import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/platform/on_device_speech_models.dart';
import 'package:wordnest/core/speech/platform_speech_recognizer.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';

import '../../fakes/fake_platform_speech.dart';

void main() {
  late FakePlatformSpeech platform;
  late PlatformSpeechRecognizer recognizer;

  setUp(() {
    platform = FakePlatformSpeech();
    recognizer = PlatformSpeechRecognizer(
      speech: platform,
      onDeviceModels: const _FakeOnDeviceSpeechModels(['en_US']),
      listenStartTimeout: const Duration(milliseconds: 20),
    );
  });

  tearDown(() => recognizer.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('hands-free restarts', () {
    test('waits for the platform to release the recogniser', () async {
      await recognizer.start(
        languageCode: 'en',
        mode: ListeningMode.continuous,
      );
      expect(platform.sessions, hasLength(1));

      // Android delivers the final result while it still holds the recogniser.
      // Opening the next session here is what earns ERROR_RECOGNIZER_BUSY.
      platform.emitFinalResult('the quick brown fox');
      await settle();
      expect(
        platform.sessions,
        hasLength(1),
        reason: 'the next session must not open on the result',
      );

      platform.emitDone();
      await settle();
      expect(
        platform.sessions,
        hasLength(2),
        reason: 'it opens once the platform says it is done',
      );
    });

    test('a single-shot session does not restart', () async {
      await recognizer.start(languageCode: 'en');
      platform.emitFinalResult('the quick brown fox');
      platform.emitDone();
      await settle();

      expect(platform.sessions, hasLength(1));
    });

    test('a stop between the result and done cancels the restart', () async {
      await recognizer.start(
        languageCode: 'en',
        mode: ListeningMode.continuous,
      );
      platform.emitFinalResult('the quick brown fox');
      await recognizer.stop();
      platform.emitDone();
      await settle();

      expect(
        platform.sessions,
        hasLength(1),
        reason: 'a session the user ended must stay ended',
      );
    });
  });

  group('recognition route', () {
    test('uses on-device only for an installed language', () async {
      final events = <SpeechEvent>[];
      final subscription = recognizer.events.listen(events.add);
      addTearDown(subscription.cancel);

      await recognizer.start(languageCode: 'en');
      await settle();

      expect(platform.sessions.single.onDevice, isTrue);
      expect(
        events.whereType<SpeechRouteChanged>().single.route,
        SpeechRoute.onDevice,
      );
    });

    test('starts online directly when the model is not installed', () async {
      await recognizer.dispose();
      recognizer = PlatformSpeechRecognizer(
        speech: platform,
        onDeviceModels: const _FakeOnDeviceSpeechModels([]),
        listenStartTimeout: const Duration(milliseconds: 20),
      );
      final events = <SpeechEvent>[];
      final subscription = recognizer.events.listen(events.add);
      addTearDown(subscription.cancel);

      await recognizer.start(languageCode: 'en');
      await settle();

      expect(platform.sessions.single.onDevice, isFalse);
      expect(
        events.whereType<SpeechRouteChanged>().single.route,
        SpeechRoute.phoneOnline,
      );
    });

    test(
      'an installed regional model determines the requested locale',
      () async {
        await recognizer.dispose();
        recognizer = PlatformSpeechRecognizer(
          speech: platform,
          onDeviceModels: const _FakeOnDeviceSpeechModels(['en_GB']),
          listenStartTimeout: const Duration(milliseconds: 20),
        );

        await recognizer.start(languageCode: 'en');

        expect(platform.sessions.single.localeId, 'en_GB');
        expect(platform.sessions.single.onDevice, isTrue);
      },
    );

    test(
      'does not claim listening when the platform rejects the start',
      () async {
        platform
          ..acceptListen = false
          ..announceListening = false;

        await expectLater(
          recognizer.start(languageCode: 'en'),
          throwsA(
            isA<SpeechFailure>().having(
              (failure) => failure.detail,
              'detail',
              'listen_not_started',
            ),
          ),
        );
      },
    );

    test('ignores a result callback from a cancelled session', () async {
      final finals = <SpeechFinal>[];
      final subscription = recognizer.events
          .where((event) => event is SpeechFinal)
          .cast<SpeechFinal>()
          .listen(finals.add);
      addTearDown(subscription.cancel);

      await recognizer.start(languageCode: 'en');
      await recognizer.cancel();
      await recognizer.start(languageCode: 'en');

      platform.emitFinalResultForSession(0, 'stale words');
      await settle();
      expect(finals, isEmpty);

      platform.emitFinalResultForSession(1, 'current words');
      await settle();
      expect(finals.single.text, 'current words');
    });
  });

  group('what the platform errors mean', () {
    Future<SpeechFailure> failureFrom(String errorMsg) async {
      await recognizer.start(languageCode: 'en');
      final failure = recognizer.events
          .where((event) => event is SpeechFailed)
          .cast<SpeechFailed>()
          .map((event) => event.failure)
          .first;
      platform.emitError(errorMsg);
      return failure;
    }

    test('a network error is not blamed on the recogniser', () async {
      expect(
        (await failureFrom('error_network')).kind,
        SpeechFailureKind.networkUnavailable,
      );
    });

    test('a server error reads the same way to the user', () async {
      expect(
        (await failureFrom('error_server')).kind,
        SpeechFailureKind.networkUnavailable,
      );
    });

    test('being rate limited is not a broken microphone', () async {
      expect(
        (await failureFrom('error_too_many_requests')).kind,
        SpeechFailureKind.networkUnavailable,
      );
    });

    test('an audio error names the microphone', () async {
      expect(
        (await failureFrom('error_audio_error')).kind,
        SpeechFailureKind.audioUnavailable,
      );
    });

    test('a busy recogniser is still the catch-all', () async {
      expect(
        (await failureFrom('error_busy')).kind,
        SpeechFailureKind.recognitionFailed,
      );
    });

    test('an unknown error is still the catch-all', () async {
      expect(
        (await failureFrom('error_unknown (42)')).kind,
        SpeechFailureKind.recognitionFailed,
      );
    });
  });
}

class _FakeOnDeviceSpeechModels implements OnDeviceSpeechModels {
  const _FakeOnDeviceSpeechModels(this.locales);

  final List<String>? locales;

  @override
  Future<List<String>?> installedLocaleIds() async => locales;
}

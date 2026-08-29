import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/platform_speech_recognizer.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';

import '../../fakes/fake_platform_speech.dart';

void main() {
  late FakePlatformSpeech platform;
  late PlatformSpeechRecognizer recognizer;

  setUp(() {
    platform = FakePlatformSpeech();
    recognizer = PlatformSpeechRecognizer(speech: platform);
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
      expect(platform.sessions, hasLength(1),
          reason: 'the next session must not open on the result');

      platform.emitDone();
      await settle();
      expect(platform.sessions, hasLength(2),
          reason: 'it opens once the platform says it is done');
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

      expect(platform.sessions, hasLength(1),
          reason: 'a session the user ended must stay ended');
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
      expect((await failureFrom('error_network')).kind,
          SpeechFailureKind.networkUnavailable);
    });

    test('a server error reads the same way to the user', () async {
      expect((await failureFrom('error_server')).kind,
          SpeechFailureKind.networkUnavailable);
    });

    test('being rate limited is not a broken microphone', () async {
      expect((await failureFrom('error_too_many_requests')).kind,
          SpeechFailureKind.networkUnavailable);
    });

    test('an audio error names the microphone', () async {
      expect((await failureFrom('error_audio_error')).kind,
          SpeechFailureKind.audioUnavailable);
    });

    test('a busy recogniser is still the catch-all', () async {
      expect((await failureFrom('error_busy')).kind,
          SpeechFailureKind.recognitionFailed);
    });

    test('an unknown error is still the catch-all', () async {
      expect((await failureFrom('error_unknown (42)')).kind,
          SpeechFailureKind.recognitionFailed);
    });
  });
}

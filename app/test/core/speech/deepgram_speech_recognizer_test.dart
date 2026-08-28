import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/deepgram_speech_recognizer.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';
import 'package:wordnest/core/speech/speech_socket.dart';

import '../../fakes/fake_microphone_stream.dart';
import '../../fakes/fake_speech_socket.dart';

/// Stands in for the stream closing, so a test can tell "nothing arrived"
/// from "the stream ended".
const _done = SpeechLifecycleChanged(SpeechLifecycle.idle);

/// The cloud recognition path, driven entirely through fakes: no microphone,
/// no socket, no network.
void main() {
  late FakeMicrophoneStream microphone;
  late FakeSpeechSocketFactory sockets;
  late DeepgramSpeechRecognizer recognizer;
  late List<SpeechEvent> events;

  DeepgramSpeechRecognizer build({
    SpeechSocketFactory? connect,
    String? token = 'a-token',
    String? renewed = 'a-renewed-token',
  }) {
    final built = DeepgramSpeechRecognizer(
      microphone: microphone,
      connect: connect ?? sockets.connect,
      credentials: ({bool renew = false}) async => renew ? renewed : token,
    );
    events = [];
    built.events.listen(events.add);
    return built;
  }

  setUp(() {
    microphone = FakeMicrophoneStream();
    sockets = FakeSpeechSocketFactory();
  });

  tearDown(() => recognizer.dispose());

  group('starting a session', () {
    test('opens the socket before it opens the microphone', () async {
      // The ordering is the no-buffering guarantee: there must be no moment in
      // which audio exists with nowhere to send it.
      recognizer = build();

      await recognizer.start(languageCode: 'en');

      expect(sockets.socket.connectedAt, isNotNull);
      expect(microphone.openedAt, isNotNull);
      expect(
        sockets.socket.connectedAt!.isAfter(microphone.openedAt!),
        isFalse,
      );
    });

    test('sends the language the caller asked for', () async {
      recognizer = build();

      await recognizer.start(languageCode: 'sv');

      expect(sockets.languages, ['sv']);
    });

    test('announces where the voice is going before it starts listening',
        () async {
      recognizer = build();

      await recognizer.start(languageCode: 'en');
      await pumpEventQueue();

      final route = events.whereType<SpeechRouteChanged>().single;
      final listening = events.indexWhere(
        (event) =>
            event is SpeechLifecycleChanged &&
            event.lifecycle == SpeechLifecycle.listening,
      );
      expect(route.route, SpeechRoute.wordnestServer);
      expect(events.indexOf(route), lessThan(listening));
    });

    test('never opens the microphone when there is no session yet', () async {
      recognizer = build(token: null);

      await expectLater(
        recognizer.start(languageCode: 'en'),
        throwsA(isA<SpeechFailure>().having(
          (failure) => failure.kind,
          'kind',
          SpeechFailureKind.serviceUnreachable,
        )),
      );
      expect(microphone.openCount, 0);
    });

    test('never opens the microphone when the server refuses', () async {
      recognizer = build(connect: alwaysRefusing());

      await expectLater(
        recognizer.start(languageCode: 'en'),
        throwsA(isA<SpeechFailure>()),
      );
      expect(microphone.openCount, 0);
    });

    test('a refused session is transient, so the caller may fall back',
        () async {
      recognizer = build(connect: alwaysRefusing());

      await expectLater(
        recognizer.start(languageCode: 'en'),
        throwsA(isA<SpeechFailure>()
            .having((f) => f.kind, 'kind', SpeechFailureKind.serviceUnreachable)
            .having((f) => f.isPermanent, 'isPermanent', false)),
      );
    });

    test('a denied microphone is reported as such, not as an outage', () async {
      microphone.permission = false;
      recognizer = build();

      await expectLater(
        recognizer.start(languageCode: 'en'),
        throwsA(isA<SpeechFailure>().having(
          (failure) => failure.kind,
          'kind',
          SpeechFailureKind.permissionDenied,
        )),
      );
    });

    test('renews the session once when the server says the token is stale',
        () async {
      sockets.rejectWith = const SpeechSocketRejected(
        closeCode: SpeechCloseCodes.unauthenticated,
      );
      recognizer = build();

      await recognizer.start(languageCode: 'en');

      expect(sockets.attempts, 2);
      expect(sockets.tokens, ['a-token', 'a-renewed-token']);
    });

    test('gives up when the renewed session is refused too', () async {
      // A second refusal means the session is gone; retrying past that would
      // only hide it.
      recognizer = build(
        connect: alwaysRefusing(closeCode: SpeechCloseCodes.unauthenticated),
      );

      await expectLater(
        recognizer.start(languageCode: 'en'),
        throwsA(isA<SpeechFailure>()),
      );
    });

    test('a second start does not leave two microphones open', () async {
      recognizer = build();

      await recognizer.start(languageCode: 'en');
      await recognizer.start(languageCode: 'en');

      expect(microphone.closeCount, greaterThanOrEqualTo(1));
      expect(microphone.openCount - microphone.closeCount, lessThanOrEqualTo(1));
    });
  });

  group('carrying audio', () {
    test('every frame reaches the socket, whole', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      microphone
        ..emit([1, 2, 3, 4])
        ..emit([5, 6])
        ..emit([7, 8, 9, 10, 11, 12]);
      await pumpEventQueue();

      expect(sockets.socket.frameCount, 3);
      expect(sockets.socket.byteCount, 12);
    });

    test('frames arriving after the session ends are dropped, not queued',
        () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');
      final live = microphone;

      await recognizer.cancel();
      live.emit([1, 2, 3, 4]);
      await pumpEventQueue();

      expect(sockets.socket.frameCount, 0);
    });

    test('reports a sound level for the animation', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      microphone.emitSpeech(level: 0.8);
      await pumpEventQueue();

      final levels = events.whereType<SpeechSoundLevel>();
      expect(levels, isNotEmpty);
      expect(levels.first.level, greaterThan(0));
      expect(levels.first.level, lessThanOrEqualTo(1));
    });
  });

  group('transcripts', () {
    test('a partial becomes a partial', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket.emitPartial('the bakery');
      await pumpEventQueue();

      expect(events.whereType<SpeechPartial>().single.text, 'the bakery');
    });

    test('a final carries its confidence through', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket.emitFinal('the bakery is closed', confidence: 0.94);
      await pumpEventQueue();

      final result = events.whereType<SpeechFinal>().single;
      expect(result.text, 'the bakery is closed');
      expect(result.confidence, 0.94);
    });

    test('an empty final says nothing was heard', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket.emitFinal('   ');
      await pumpEventQueue();

      expect(events.whereType<SpeechFinal>(), isEmpty);
      expect(
        events.whereType<SpeechFailed>().single.failure.kind,
        SpeechFailureKind.noSpeechDetected,
      );
    });

    test('hands-free keeps one socket across several utterances', () async {
      recognizer = build();
      await recognizer.start(
        languageCode: 'en',
        mode: ListeningMode.continuous,
      );

      sockets.socket
        ..emitFinal('the bakery is closed')
        ..emitFinal('so is the bank');
      await pumpEventQueue();

      expect(events.whereType<SpeechFinal>().length, 2);
      expect(sockets.attempts, 1);
      expect(microphone.openCount, 1);
      expect(sockets.socket.closed, isFalse);
    });

    test('hold-to-talk ends the session on its one final', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket.emitFinal('the bakery is closed');
      await pumpEventQueue();

      expect(sockets.socket.closed, isTrue);
      expect(recognizer.isListening, isFalse);
    });

    test('a frame type this version does not know is ignored, not fatal',
        () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket
        ..emitUnknownFrame()
        ..emitFinal('still here');
      await pumpEventQueue();

      expect(events.whereType<SpeechFinal>().single.text, 'still here');
    });
  });

  group('failures', () {
    test('an unsupported language is permanent, so the caller stops asking',
        () async {
      recognizer = build();
      await recognizer.start(languageCode: 'cy');

      sockets.socket.emitError('SPEECH_LANGUAGE_UNSUPPORTED');
      await pumpEventQueue();

      final failure = events.whereType<SpeechFailed>().single.failure;
      expect(failure.kind, SpeechFailureKind.localeUnsupported);
      expect(failure.isPermanent, isTrue);
    });

    test('an outage is transient', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket.emitError('SPEECH_UNAVAILABLE');
      await pumpEventQueue();

      final failure = events.whereType<SpeechFailed>().single.failure;
      expect(failure.kind, SpeechFailureKind.serviceUnreachable);
      expect(failure.isPermanent, isFalse);
    });

    test('an unrecognised error code still reaches the user', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket.emitError('SOMETHING_NEW');
      await pumpEventQueue();

      expect(
        events.whereType<SpeechFailed>().single.failure.kind,
        SpeechFailureKind.recognitionFailed,
      );
    });

    test('a dropped connection closes the microphone rather than reconnecting',
        () async {
      // Silently reconnecting while the microphone stays open would mean the
      // user streaming to a connection they were never told had come back.
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      sockets.socket.drop();
      await pumpEventQueue();

      expect(microphone.isOpen, isFalse);
      expect(sockets.attempts, 1);
      expect(
        events.whereType<SpeechFailed>().single.failure.kind,
        SpeechFailureKind.serviceUnreachable,
      );
    });
  });

  group('ending a session', () {
    test('stop closes the microphone at once but keeps the socket open',
        () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      await recognizer.stop();

      expect(microphone.isOpen, isFalse);
      expect(sockets.socket.closed, isFalse);
      expect(sockets.socket.controls, [
        {'type': 'finalize'},
      ]);
    });

    test('cancel abandons the utterance without transcribing it', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');
      sockets.socket.emitPartial('the bak');
      await pumpEventQueue();

      await recognizer.cancel();

      expect(sockets.socket.controls.last, {'type': 'close'});
      expect(events.whereType<SpeechFinal>(), isEmpty);
      expect(microphone.isOpen, isFalse);
    });

    test('a late event after dispose is dropped, not thrown', () async {
      // The platform routes speech callbacks through one channel, so a
      // recogniser replaced mid-flight can still be handed an event the
      // platform had already queued. Adding it to a closed controller would
      // take the app down — found by running the real thing.
      recognizer = build();
      await recognizer.start(languageCode: 'en');
      final socket = sockets.socket;

      final seen = <SpeechEvent>[];
      recognizer.events.listen(seen.add, onDone: () => seen.add(_done));

      await recognizer.dispose();
      socket.emitFinal('too late');
      await pumpEventQueue();

      expect(seen.whereType<SpeechFinal>(), isEmpty);

      recognizer = build();
    });

    test('disposing closes both the microphone and the socket', () async {
      recognizer = build();
      await recognizer.start(languageCode: 'en');

      await recognizer.dispose();

      expect(microphone.isOpen, isFalse);
      expect(microphone.disposeCount, 1);
      expect(sockets.socket.closed, isTrue);

      recognizer = build();
    });
  });
}

import 'dart:async';

import 'microphone_stream.dart';
import 'speech_socket.dart';
import 'speech_recognizer.dart';

/// Supplies the bearer token for a speech session, renewing it on request.
///
/// A function rather than the app's `AccessTokens` interface on purpose: that
/// interface lives beside the dio client, and nothing in this directory may
/// import dio. A closure crosses the boundary; the dio-shaped type does not.
typedef SpeechCredentials = Future<String?> Function({bool renew});

/// [SpeechRecognizer] backed by WordNest's own server, which relays the audio
/// to a transcription service and relays the text back.
///
/// AUDIO POLICY: this file holds the session logic and nothing else. It imports
/// no package at all — the microphone and the socket are interfaces, and the
/// two implementations behind them are the only files in this directory allowed
/// to touch bytes or open a connection. Every frame is forwarded the instant it
/// arrives and no reference to it is kept; there is no accumulator here, and
/// `no_audio_persistence_test.dart` fails the build if one appears.
class DeepgramSpeechRecognizer implements SpeechRecognizer {
  DeepgramSpeechRecognizer({
    required MicrophoneStream microphone,
    required SpeechSocketFactory connect,
    required SpeechCredentials credentials,
    // ignore_for_file: prefer_initializing_formals — Dart has no initialising
    // formal for a private field behind a public named parameter.
  })  : _microphone = microphone,
        _connect = connect,
        _credentials = credentials;

  /// How long to wait for the last words after the user lets go. Beyond this
  /// the session ends rather than leaving the screen waiting for a sentence
  /// that is not coming.
  static const _finalisationGrace = Duration(seconds: 3);

  /// A hard ceiling so a forgotten hands-free session cannot hold the mic and
  /// a metered upstream session open. The same ceiling the platform path uses.
  static const _maxSessionLength = Duration(minutes: 5);

  /// Sound levels are emitted at most this often. Frames arrive far faster than
  /// an animation can use.
  static const _levelInterval = Duration(milliseconds: 100);

  final MicrophoneStream _microphone;
  final SpeechSocketFactory _connect;
  final SpeechCredentials _credentials;

  final _events = StreamController<SpeechEvent>.broadcast();

  _Session? _session;
  ListeningMode _mode = ListeningMode.single;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  /// Emits, unless this recogniser has been disposed. A socket or a microphone
  /// can deliver one last event after teardown has begun, and adding it to a
  /// closed controller would take the app down.
  void _emit(SpeechEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  /// Nothing to warm up: the socket is per-session and the token is fetched
  /// when a session starts. Saying so beats faking work.
  @override
  Future<bool> initialize() async => true;

  /// Availability here is a property of the network, and guessing at it before
  /// trying is worse than trying.
  @override
  bool get isAvailable => true;

  @override
  bool get isListening => _session?.isOpen ?? false;

  /// The contract is *platform* locale ids, and this recogniser has none —
  /// [resolveSpeechLocale] reads an empty list as "no offline model", which is
  /// exactly right for a multilingual cloud model.
  @override
  Future<List<String>> availableLocaleIds() async => const [];

  @override
  Future<void> start({
    required String languageCode,
    ListeningMode mode = ListeningMode.single,
  }) async {
    // A second start must never leave two microphones open.
    if (_session != null) await cancel();

    final token = await _credentials(renew: false);
    if (token == null) {
      throw const SpeechFailure(
        SpeechFailureKind.serviceUnreachable,
        detail: 'no session',
        isPermanent: false,
      );
    }

    if (!await _microphone.hasPermission()) {
      throw const SpeechFailure(SpeechFailureKind.permissionDenied);
    }

    // The socket opens before the microphone, always. That ordering is the
    // no-buffering guarantee: there is no moment in which audio exists with
    // nowhere to send it.
    final socket = await _openSocket(
      languageCode: languageCode,
      mode: mode,
      token: token,
    );

    _mode = mode;
    final session = _Session(socket: socket);
    _session = session;

    session.messages = socket.messages.listen(
      _onMessage,
      onError: (Object error) => _onSocketError(error),
      onDone: _onSocketDone,
    );

    try {
      session.audio = (await _microphone.open()).listen(_onFrame);
    } on Object catch (error) {
      await cancel();
      throw SpeechFailure(
        SpeechFailureKind.recognitionFailed,
        detail: '$error',
      );
    }

    session.ceiling = Timer(_maxSessionLength, stop);
    _emit(const SpeechRouteChanged(SpeechRoute.wordnestServer));
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.listening));
  }

  /// Opens the socket, renewing the session once if the server says the token
  /// is stale. Exactly once: a second refusal means the session is gone, and
  /// retrying past that would only hide it.
  Future<SpeechSocket> _openSocket({
    required String languageCode,
    required ListeningMode mode,
    required String token,
  }) async {
    try {
      return await _connect(
        languageCode: languageCode,
        mode: mode,
        bearerToken: token,
      );
    } on SpeechSocketRejected catch (rejection) {
      if (rejection.closeCode != SpeechCloseCodes.unauthenticated) {
        throw _unreachable(rejection);
      }
      final renewed = await _credentials(renew: true);
      if (renewed == null) throw _unreachable(rejection);
      try {
        return await _connect(
          languageCode: languageCode,
          mode: mode,
          bearerToken: renewed,
        );
      } on SpeechSocketRejected catch (second) {
        throw _unreachable(second);
      }
    }
  }

  static SpeechFailure _unreachable(SpeechSocketRejected rejection) {
    return SpeechFailure(
      SpeechFailureKind.serviceUnreachable,
      detail: rejection.detail ?? 'closed ${rejection.closeCode}',
      isPermanent: false,
    );
  }

  void _onFrame(AudioFrame frame) {
    final session = _session;
    if (session == null) return;
    session.socket.sendAudio(frame.bytes);
    _reportLevel(session, frame.level);
  }

  /// Smoothed and throttled: frames arrive every 20–60 ms, and an animation
  /// driven by raw values at that rate reads as noise.
  void _reportLevel(_Session session, double level) {
    session.level = session.level * 0.6 + level * 0.4;
    final now = DateTime.now();
    if (session.levelSentAt != null &&
        now.difference(session.levelSentAt!) < _levelInterval) {
      return;
    }
    session.levelSentAt = now;
    _emit(SpeechSoundLevel(session.level));
  }

  void _onMessage(Map<String, Object?> message) {
    switch (message['type']) {
      case 'partial':
        final text = (message['text'] as String? ?? '').trim();
        if (text.isNotEmpty) _emit(SpeechPartial(text));
      case 'final':
        _onFinal((message['text'] as String? ?? '').trim(), message);
      case 'error':
        _emit(SpeechFailed(_translateError(message)));
      default:
      // A server that grew a new frame type must not be able to end a
      // sentence someone is in the middle of saying.
    }
  }

  void _onFinal(String text, Map<String, Object?> message) {
    final session = _session;
    session?.finalisation?.cancel();
    session?.finalisation = null;

    if (text.isEmpty) {
      _emit(const SpeechFailed(
        SpeechFailure(SpeechFailureKind.noSpeechDetected, isPermanent: false),
      ));
    } else {
      _emit(SpeechFinal(
        text,
        confidence: (message['confidence'] as num?)?.toDouble(),
      ));
    }

    // In hands-free the socket stays open across utterances — that is the whole
    // advantage over the platform recogniser, which has to restart at each
    // pause. In hold-to-talk the utterance was the session.
    if (_mode == ListeningMode.single) {
      unawaited(_finish());
    }
  }

  static SpeechFailure _translateError(Map<String, Object?> message) {
    final detail = message['message'] as String?;
    return switch (message['code']) {
      'SPEECH_LANGUAGE_UNSUPPORTED' =>
        SpeechFailure(SpeechFailureKind.localeUnsupported, detail: detail),
      'SPEECH_UNAVAILABLE' => SpeechFailure(
          SpeechFailureKind.serviceUnreachable,
          detail: detail,
          isPermanent: false,
        ),
      'RATE_LIMITED' => SpeechFailure(
          SpeechFailureKind.serviceUnreachable,
          detail: detail,
          isPermanent: false,
        ),
      _ => SpeechFailure(SpeechFailureKind.recognitionFailed, detail: detail),
    };
  }

  void _onSocketError(Object error) {
    // Never reconnects. Silently re-establishing a socket while the microphone
    // stays open is exactly the behaviour that would make the privacy line
    // untrustworthy: the user would be streaming to a connection they were
    // never told had come back.
    final failure = error is SpeechSocketRejected
        ? _unreachable(error)
        : const SpeechFailure(
            SpeechFailureKind.serviceUnreachable,
            isPermanent: false,
          );
    unawaited(_abandon());
    _emit(SpeechFailed(failure));
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.idle));
  }

  void _onSocketDone() {
    if (_session == null) return;
    unawaited(_abandon());
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.idle));
  }

  @override
  Future<void> stop() async {
    final session = _session;
    if (session == null) return;

    // Capture ends the instant the user lets go; the socket stays open just
    // long enough for the words already sent to come back as text.
    await _microphone.close();
    await session.audio?.cancel();
    session.audio = null;
    session.socket.sendControl(const {'type': 'finalize'});
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.processing));

    session.finalisation = Timer(_finalisationGrace, () {
      _emit(const SpeechFailed(
        SpeechFailure(SpeechFailureKind.noSpeechDetected, isPermanent: false),
      ));
      unawaited(_finish());
    });
  }

  /// Ends a session that has said everything it is going to.
  Future<void> _finish() async {
    await _abandon();
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.done));
  }

  @override
  Future<void> cancel() async {
    if (_session == null) return;
    _session!.socket.sendControl(const {'type': 'close'});
    await _abandon();
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.idle));
  }

  /// Tears the session down without saying anything about it.
  Future<void> _abandon() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    _mode = ListeningMode.single;

    session.ceiling?.cancel();
    session.finalisation?.cancel();
    await session.audio?.cancel();
    await session.messages?.cancel();
    await _microphone.close();
    await session.socket.close();
  }

  @override
  Future<void> dispose() async {
    await _abandon();
    await _microphone.dispose();
    await _events.close();
  }
}

/// One live session's moving parts, so tearing it down is one place.
class _Session {
  _Session({required this.socket});

  final SpeechSocket socket;
  StreamSubscription<AudioFrame>? audio;
  StreamSubscription<Map<String, Object?>>? messages;
  Timer? ceiling;
  Timer? finalisation;
  double level = 0;
  DateTime? levelSentAt;

  bool get isOpen => audio != null;
}

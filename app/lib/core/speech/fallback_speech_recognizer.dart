import 'dart:async';

import 'speech_recognizer.dart';

/// Runs [preferred], and moves the session to [fallback] when the preferred
/// recogniser cannot be reached at all.
///
/// The app is local-first: a microphone that does nothing because a server is
/// down would be the one place that stops being true. So a session that cannot
/// start on the cloud recogniser starts on the phone instead.
///
/// This is not silent in the way that would matter. Whichever child ends up
/// running emits its own [SpeechRouteChanged], so the privacy line names where
/// the voice actually went; only the error is withheld, because the user can
/// see the route for themselves and there is nothing for them to do about it
/// mid-sentence.
class FallbackSpeechRecognizer implements SpeechRecognizer {
  FallbackSpeechRecognizer({
    required SpeechRecognizer preferred,
    required SpeechRecognizer fallback,
    // ignore_for_file: prefer_initializing_formals — Dart has no initialising
    // formal for a private field behind a public named parameter.
  }) : _preferred = preferred,
       _fallback = fallback {
    _forward(_preferred);
    _forward(_fallback);
  }

  final SpeechRecognizer _preferred;
  final SpeechRecognizer _fallback;

  final _events = StreamController<SpeechEvent>.broadcast();
  final _forwarding = <StreamSubscription<SpeechEvent>>[];

  /// The child that owns the running session, so stop and cancel reach the one
  /// that is actually listening.
  SpeechRecognizer? _active;
  int _sessionGeneration = 0;

  void _forward(SpeechRecognizer child) {
    // Events from the child that is not running are dropped rather than
    // relayed: a torn-down session must not be able to speak over a live one.
    _forwarding.add(
      child.events.listen((event) {
        if (identical(_active, child) && !_events.isClosed) _events.add(event);
      }),
    );
  }

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  Future<bool> initialize() async {
    final results = await Future.wait([
      _preferred.initialize(),
      _fallback.initialize(),
    ]);
    return results.any((worked) => worked);
  }

  @override
  bool get isAvailable => _preferred.isAvailable || _fallback.isAvailable;

  @override
  bool get isListening => _active?.isListening ?? false;

  @override
  Future<List<String>> availableLocaleIds() => _fallback.availableLocaleIds();

  @override
  Future<void> start({
    required String languageCode,
    ListeningMode mode = ListeningMode.single,
  }) async {
    final generation = ++_sessionGeneration;
    _active = _preferred;
    try {
      await _preferred.start(languageCode: languageCode, mode: mode);
      if (generation != _sessionGeneration) {
        await _preferred.cancel();
      }
      return;
    } on SpeechFailure catch (failure) {
      if (generation != _sessionGeneration) return;
      if (!_isWorthFallingBackFrom(failure)) {
        _active = null;
        rethrow;
      }
    }

    // Only reached when the preferred recogniser could not be reached at all,
    // so there is no session of its to tear down.
    if (generation != _sessionGeneration) return;
    _active = _fallback;
    try {
      await _fallback.start(languageCode: languageCode, mode: mode);
      if (generation != _sessionGeneration) {
        await _fallback.cancel();
      }
    } on SpeechFailure {
      if (generation != _sessionGeneration) return;
      _active = null;
      rethrow;
    }
  }

  /// A service that cannot be reached is worth trying the phone for. A refused
  /// microphone or an unrecognised language is not: the phone would fail the
  /// same way, and pretending otherwise would just delay the truth.
  static bool _isWorthFallingBackFrom(SpeechFailure failure) =>
      failure.kind == SpeechFailureKind.serviceUnreachable ||
      failure.kind == SpeechFailureKind.unavailable;

  @override
  Future<void> stop() async => _active?.stop();

  @override
  Future<void> cancel() async {
    _sessionGeneration++;
    final active = _active;
    _active = null;
    await active?.cancel();
  }

  @override
  Future<void> dispose() async {
    _sessionGeneration++;
    _active = null;
    for (final subscription in _forwarding) {
      await subscription.cancel();
    }
    await _preferred.dispose();
    await _fallback.dispose();
    await _events.close();
  }
}

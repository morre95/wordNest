import 'dart:async';

import 'package:wordnest/core/speech/speech_recognizer.dart';

/// A [SpeechRecognizer] driven by the test rather than by a microphone.
///
/// Tests push transcripts through [emitPartial] / [emitFinal] exactly as the
/// platform would. Nothing here opens an audio source, so widget tests run
/// with no platform channels at all.
class FakeSpeechRecognizer implements SpeechRecognizer {
  FakeSpeechRecognizer({
    this.available = true,
    this.locales = const ['en_US', 'es_ES', 'sv_SE'],
    this.failOnStart,
    this.announceListening = true,
  });

  bool available;
  List<String> locales;

  /// When set, [start] throws this instead of starting a session.
  SpeechFailure? failOnStart;
  bool announceListening;
  Future<void>? startGate;

  final _events = StreamController<SpeechEvent>.broadcast();
  final startedLanguages = <String>[];
  final startedModes = <ListeningMode>[];
  int stopCount = 0;
  int cancelCount = 0;

  /// Whether [dispose] has run. An engine swap that leaks the old recogniser
  /// leaks a microphone with it, so a test needs to be able to see this.
  bool disposed = false;

  bool _listening = false;

  @override
  bool get isAvailable => available;

  @override
  bool get isListening => _listening;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  Future<bool> initialize() async => available;

  @override
  Future<List<String>> availableLocaleIds() async => locales;

  @override
  Future<void> start({
    required String languageCode,
    ListeningMode mode = ListeningMode.single,
  }) async {
    final gate = startGate;
    if (gate != null) await gate;
    if (failOnStart != null) throw failOnStart!;
    startedLanguages.add(languageCode);
    startedModes.add(mode);
    _listening = true;
    if (announceListening) {
      _events.add(const SpeechLifecycleChanged(SpeechLifecycle.listening));
    }
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _listening = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }

  // --- Test drivers -------------------------------------------------------

  void emitPartial(String text) => _events.add(SpeechPartial(text));

  void emitFinal(String text, {double? confidence}) {
    _listening = false;
    _events.add(SpeechFinal(text, confidence: confidence));
  }

  void emitSoundLevel(double level) => _events.add(SpeechSoundLevel(level));

  void emitLifecycle(SpeechLifecycle lifecycle) =>
      _events.add(SpeechLifecycleChanged(lifecycle));

  void emitFailure(SpeechFailure failure) => _events.add(SpeechFailed(failure));

  void emitRoute(SpeechRoute route) => _events.add(SpeechRouteChanged(route));
}

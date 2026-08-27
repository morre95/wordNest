import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import 'speaker.dart';

/// [Speaker] backed by the platform text-to-speech engine.
///
/// The only file that knows `flutter_tts` exists.
class PlatformSpeaker implements Speaker {
  PlatformSpeaker({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  /// Which languages the engine can actually speak, asked once and kept: the
  /// answer does not change while the app is running, and asking on every tap
  /// adds a platform round trip to something meant to feel instant.
  final _availability = <String, bool>{};

  Completer<void>? _speaking;
  bool _configured = false;

  @override
  Future<bool> canSpeak(String languageCode) async {
    final cached = _availability[languageCode];
    if (cached != null) return cached;
    final available = await _tts.isLanguageAvailable(languageCode) == true;
    _availability[languageCode] = available;
    return available;
  }

  @override
  Future<void> speak(String text, {required String languageCode}) async {
    if (text.trim().isEmpty) return;
    if (!await canSpeak(languageCode)) {
      throw SpeakerFailure(
        SpeakerFailureKind.voiceUnavailable,
        languageCode: languageCode,
      );
    }

    await _configure();
    await stop();

    final completed = Completer<void>();
    _speaking = completed;
    _tts.setCompletionHandler(() => _finish(completed));
    _tts.setCancelHandler(() => _finish(completed));
    _tts.setErrorHandler((dynamic message) => _finish(completed));

    await _tts.setLanguage(languageCode);
    await _tts.speak(text);
    return completed.future;
  }

  Future<void> _configure() async {
    if (_configured) return;
    // Awaiting each utterance is what lets `speak` complete when playback ends
    // rather than when it starts, which the review screen relies on.
    await _tts.awaitSpeakCompletion(true);
    // A shade slower than default: this is a pronunciation model, and the
    // point is to be imitable.
    await _tts.setSpeechRate(0.45);
    _configured = true;
  }

  void _finish(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
    if (identical(_speaking, completer)) _speaking = null;
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
    final pending = _speaking;
    if (pending != null) _finish(pending);
  }

  @override
  Future<void> dispose() => stop();
}

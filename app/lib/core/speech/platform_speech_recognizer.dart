import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'speech_recognizer.dart';

/// [SpeechRecognizer] backed by the platform recogniser (Android
/// `SpeechRecognizer`, iOS `SFSpeechRecognizer`) via `speech_to_text`.
///
/// AUDIO POLICY: `speech_to_text` streams microphone audio inside the platform
/// recogniser and hands us transcription callbacks. No audio buffer is exposed
/// to Dart, so there is nothing here that could be written to disk even by
/// accident — and nothing in this file opens a file or a socket.
class PlatformSpeechRecognizer implements SpeechRecognizer {
  PlatformSpeechRecognizer({stt.SpeechToText? speech})
      : _speech = speech ?? stt.SpeechToText();

  /// How long a pause ends an utterance. Long enough to think mid-sentence,
  /// short enough that a translation feels immediate.
  static const _pauseBeforeFinalising = Duration(seconds: 2);

  /// A hard ceiling so a forgotten hands-free session cannot hold the mic open.
  static const _maxSessionLength = Duration(minutes: 5);

  final stt.SpeechToText _speech;
  final _events = StreamController<SpeechEvent>.broadcast();

  bool _initialised = false;
  bool _initialising = false;
  Future<bool>? _initialisation;
  ListeningMode _mode = ListeningMode.single;
  String? _languageCode;

  @override
  bool get isAvailable => _initialised && _speech.isAvailable;

  @override
  bool get isListening => _speech.isListening;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  Future<bool> initialize() {
    if (_initialised) return Future.value(true);
    if (_initialising) return _initialisation!;
    _initialising = true;
    _initialisation = _speech
        .initialize(onError: _onPlatformError, onStatus: _onPlatformStatus)
        .then((worked) {
      _initialised = worked;
      _initialising = false;
      return worked;
    }).catchError((Object error) {
      _initialising = false;
      _events.add(SpeechFailed(
        SpeechFailure(SpeechFailureKind.unavailable, detail: '$error'),
      ));
      return false;
    });
    return _initialisation!;
  }

  @override
  Future<List<String>> availableLocaleIds() async {
    if (!await initialize()) return const [];
    final locales = await _speech.locales();
    return locales.map((locale) => locale.localeId).toList(growable: false);
  }

  @override
  Future<void> start({
    required String languageCode,
    ListeningMode mode = ListeningMode.single,
  }) async {
    if (!await initialize()) {
      throw const SpeechFailure(SpeechFailureKind.unavailable);
    }
    if (!await _speech.hasPermission) {
      throw const SpeechFailure(SpeechFailureKind.permissionDenied);
    }

    final systemLocale = await _speech.systemLocale();
    final localeId = resolveSpeechLocaleId(
      languageCode: languageCode,
      availableLocaleIds: await availableLocaleIds(),
      systemLocaleId: systemLocale?.localeId,
    );
    if (localeId == null) {
      throw SpeechFailure(
        SpeechFailureKind.localeUnsupported,
        detail: languageCode,
      );
    }

    _mode = mode;
    _languageCode = languageCode;

    // On-device recognition is preferred so audio never reaches a server. Some
    // devices have no on-device model for the locale; there we fall back to the
    // platform default and tell the user, rather than refusing to listen.
    var startedOnDevice = true;
    try {
      await _listen(localeId: localeId, onDevice: true);
    } on Exception {
      startedOnDevice = false;
      await _listen(localeId: localeId, onDevice: false);
    }
    _onDeviceRecognition = startedOnDevice;
    _events.add(const SpeechLifecycleChanged(SpeechLifecycle.listening));
  }

  bool _onDeviceRecognition = true;

  /// Whether the last session ran fully on-device. The speak screen surfaces
  /// this so the privacy line stays honest.
  bool get isOnDeviceRecognition => _onDeviceRecognition;

  Future<void> _listen({required String localeId, required bool onDevice}) {
    return _speech.listen(
      onResult: _onResult,
      onSoundLevelChange: _onSoundLevel,
      listenOptions: stt.SpeechListenOptions(
        localeId: localeId,
        onDevice: onDevice,
        partialResults: true,
        cancelOnError: false,
        listenMode: stt.ListenMode.dictation,
        autoPunctuation: true,
        pauseFor: _pauseBeforeFinalising,
        listenFor: _maxSessionLength,
      ),
    );
  }

  void _onResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (result.finalResult) {
      if (text.isEmpty) {
        _events.add(const SpeechFailed(
          SpeechFailure(SpeechFailureKind.noSpeechDetected, isPermanent: false),
        ));
      } else {
        _events.add(SpeechFinal(text, confidence: result.confidence));
      }
      if (_mode == ListeningMode.continuous && _languageCode != null) {
        // Hands-free: the platform ends the session at each pause, so start the
        // next one immediately. Failures surface as events, not exceptions.
        unawaited(_restartContinuous());
      }
    } else if (text.isNotEmpty) {
      _events.add(SpeechPartial(text));
    }
  }

  Future<void> _restartContinuous() async {
    try {
      await start(languageCode: _languageCode!, mode: ListeningMode.continuous);
    } on SpeechFailure catch (failure) {
      _events.add(SpeechFailed(failure));
    }
  }

  void _onSoundLevel(double level) {
    // speech_to_text reports roughly -2..10 on Android and dB on iOS; clamp to
    // a 0..1 band the animation can use without knowing the platform.
    _events.add(SpeechSoundLevel((level / 10).clamp(0.0, 1.0)));
  }

  void _onPlatformStatus(String status) {
    final lifecycle = switch (status) {
      'listening' => SpeechLifecycle.listening,
      'notListening' => SpeechLifecycle.processing,
      'done' => SpeechLifecycle.done,
      _ => null,
    };
    if (lifecycle != null) _events.add(SpeechLifecycleChanged(lifecycle));
  }

  void _onPlatformError(SpeechRecognitionError error) {
    _events.add(SpeechFailed(_translateError(error)));
  }

  static SpeechFailure _translateError(SpeechRecognitionError error) {
    final kind = switch (error.errorMsg) {
      'error_speech_timeout' || 'error_no_match' =>
        SpeechFailureKind.noSpeechDetected,
      'error_permission' => SpeechFailureKind.permissionDenied,
      'error_language_not_supported' ||
      'error_language_unavailable' =>
        SpeechFailureKind.localeUnsupported,
      'error_busy' || 'error_client' => SpeechFailureKind.recognitionFailed,
      _ => SpeechFailureKind.recognitionFailed,
    };
    return SpeechFailure(
      kind,
      detail: error.errorMsg,
      isPermanent: error.permanent,
    );
  }

  @override
  Future<void> stop() async {
    _mode = ListeningMode.single;
    await _speech.stop();
  }

  @override
  Future<void> cancel() async {
    _mode = ListeningMode.single;
    await _speech.cancel();
    _events.add(const SpeechLifecycleChanged(SpeechLifecycle.idle));
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _events.close();
  }
}

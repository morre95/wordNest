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
/// accident — and nothing in this file opens a file or a socket. This is the
/// default engine, and the one on which WordNest still never handles audio at
/// all.
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
  String? _localeId;
  bool _onDevice = true;

  /// Set when a hands-free utterance finishes, cleared when the next session
  /// has been asked for. The restart waits for the platform to say `done`
  /// rather than happening in the result callback: Android has not released
  /// the recogniser at the moment a final result arrives, and starting there
  /// earns ERROR_RECOGNIZER_BUSY instead of a session.
  bool _restartWhenDone = false;

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
      _emit(SpeechFailed(
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
    final locale = resolveSpeechLocale(
      languageCode: languageCode,
      availableLocaleIds: await availableLocaleIds(),
      systemLocaleId: systemLocale?.localeId,
    );

    _mode = mode;
    _languageCode = languageCode;
    _localeId = locale.localeId;

    // On-device recognition is preferred so audio never reaches a server, but
    // only for a locale the device actually has a model for: the offline
    // recogniser does not degrade gracefully, it fails the whole session. A
    // language it has never heard of goes straight to the networked recogniser.
    _onDevice = locale.hasOnDeviceModel;
    try {
      await _listen(localeId: locale.localeId, onDevice: _onDevice);
    } on Exception catch (error) {
      throw SpeechFailure(
        SpeechFailureKind.recognitionFailed,
        detail: '$error',
      );
    }
    _announceListening();
  }

  void _announceListening() {
    _emit(SpeechRouteChanged(
      _onDevice ? SpeechRoute.onDevice : SpeechRoute.phoneOnline,
    ));
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.listening));
  }

  /// Emits, unless this recogniser has been disposed.
  ///
  /// `speech_to_text` routes its callbacks through one platform channel, so a
  /// recogniser replaced mid-flight — by the user changing engine, say — can
  /// still be handed an error the platform had already queued. Emitting it
  /// would add to a closed controller and take the app down.
  void _emit(SpeechEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

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
        _emit(const SpeechFailed(
          SpeechFailure(SpeechFailureKind.noSpeechDetected, isPermanent: false),
        ));
      } else {
        _emit(SpeechFinal(text, confidence: result.confidence));
      }
      if (_mode == ListeningMode.continuous && _languageCode != null) {
        // Hands-free: the platform ends the session at each pause and the next
        // one opens on `done`, once the recogniser has actually been released.
        _restartWhenDone = true;
      }
    } else if (text.isNotEmpty) {
      _emit(SpeechPartial(text));
    }
  }

  Future<void> _restartContinuous() async {
    try {
      await start(languageCode: _languageCode!, mode: ListeningMode.continuous);
    } on SpeechFailure catch (failure) {
      _emit(SpeechFailed(failure));
    }
  }

  void _onSoundLevel(double level) {
    // speech_to_text reports roughly -2..10 on Android and dB on iOS; clamp to
    // a 0..1 band the animation can use without knowing the platform.
    _emit(SpeechSoundLevel((level / 10).clamp(0.0, 1.0)));
  }

  void _onPlatformStatus(String status) {
    final lifecycle = switch (status) {
      'listening' => SpeechLifecycle.listening,
      'notListening' => SpeechLifecycle.processing,
      'done' => SpeechLifecycle.done,
      _ => null,
    };
    if (lifecycle != null) _emit(SpeechLifecycleChanged(lifecycle));

    if (status != 'done' || !_restartWhenDone) return;
    _restartWhenDone = false;
    // A stop or a cancel between the result and this point turns hands-free
    // off, and the session the user ended must stay ended.
    if (_mode != ListeningMode.continuous || _languageCode == null) return;
    unawaited(_restartContinuous());
  }

  void _onPlatformError(SpeechRecognitionError error) {
    final failure = _translateError(error);
    // The offline recogniser reports an unusable model asynchronously, once the
    // session is already running, so this is the only place the fallback can
    // live. A locale it cannot serve is not a locale the phone cannot hear —
    // the networked recogniser still can — so move there instead of telling the
    // user their device does not speak their language.
    if (_onDevice && failure.kind == SpeechFailureKind.localeUnsupported) {
      unawaited(_retryOffDevice());
      return;
    }
    _emit(SpeechFailed(failure));
  }

  /// Restarts the session on the networked recogniser. [_onDevice] is cleared
  /// first so a second locale failure reaches the user instead of looping.
  Future<void> _retryOffDevice() async {
    _onDevice = false;
    try {
      await _listen(localeId: _localeId!, onDevice: false);
    } on Exception catch (error) {
      _emit(SpeechFailed(SpeechFailure(
        SpeechFailureKind.recognitionFailed,
        detail: '$error',
      )));
      return;
    }
    _announceListening();
  }

  static SpeechFailure _translateError(SpeechRecognitionError error) {
    final kind = switch (error.errorMsg) {
      'error_speech_timeout' || 'error_no_match' =>
        SpeechFailureKind.noSpeechDetected,
      'error_permission' => SpeechFailureKind.permissionDenied,
      'error_language_not_supported' ||
      'error_language_unavailable' =>
        SpeechFailureKind.localeUnsupported,
      // The networked recogniser is reached over the internet, so these say
      // nothing about the microphone or the language — only that the service
      // behind it is out of reach right now.
      'error_network' ||
      'error_network_timeout' ||
      'error_server' ||
      'error_server_disconnected' ||
      'error_too_many_requests' =>
        SpeechFailureKind.networkUnavailable,
      'error_audio_error' => SpeechFailureKind.audioUnavailable,
      // Busy and client errors are the recogniser tripping over itself; a
      // second attempt usually works, which is all the user can be told.
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
    _restartWhenDone = false;
    await _speech.stop();
  }

  @override
  Future<void> cancel() async {
    _mode = ListeningMode.single;
    _restartWhenDone = false;
    await _speech.cancel();
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.idle));
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _events.close();
  }
}
